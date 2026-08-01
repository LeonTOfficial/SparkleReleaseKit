import CryptoKit
import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("SparkleReleaseKit self-update")
struct SelfUpdateTests {
    @Test("Reports when no newer signed version is available")
    func noUpdateAvailable() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.0")
        defer { fixture.remove() }

        let result = try fixture.updater().check(
            installedVersion: "0.4.0"
        )

        #expect(!result.updateAvailable)
        #expect(result.availableVersion == "0.4.0")
        #expect(!fixture.transport.downloadCalled)
    }

    @Test("Installs a valid signed update atomically")
    func installsValidUpdate() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        let originalDigest = try FileDigest.sha256(
            of: fixture.installationPath
        )

        let result = try fixture.updater().install(
            installedVersion: "0.4.0",
            installationPath: fixture.installationPath
        )

        let destination = try FileManager.default
            .destinationOfSymbolicLink(
                atPath: fixture.installationPath.path
            )
        let installed = URL(
            fileURLWithPath: destination,
            relativeTo: fixture.installationPath.deletingLastPathComponent()
        ).standardizedFileURL
        #expect(result.installedVersion == "0.4.1")
        #expect(try FileDigest.sha256(of: installed) == fixture.assetBinaryDigest)
        #expect(try FileDigest.sha256(of: installed) != originalDigest)
        #expect(FileManager.default.fileExists(atPath: result.backupPath))
        #expect(destination.contains("/.sparklekit/versions/"))
    }

    @Test("Rejects a manifest modified after signing")
    func rejectsTamperedManifest() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        fixture.transport.manifest.append(Data(" ".utf8))

        #expect(throws: SelfUpdateError.invalidManifestSignature) {
            try fixture.updater().check(installedVersion: "0.4.0")
        }
        #expect(!fixture.transport.downloadCalled)
    }

    @Test("Rejects an invalid manifest signature")
    func rejectsInvalidSignature() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        fixture.transport.signature = Data(
            Data(repeating: 9, count: 64).base64EncodedString().utf8
        )

        #expect(throws: SelfUpdateError.invalidManifestSignature) {
            try fixture.updater().check(installedVersion: "0.4.0")
        }
        #expect(!fixture.transport.downloadCalled)
    }

    @Test("Rejects an asset whose SHA-256 differs from the signed manifest")
    func rejectsWrongAssetDigest() throws {
        let fixture = try SelfUpdateFixture(
            version: "0.4.1",
            manifestDigest: String(repeating: "0", count: 64)
        )
        defer { fixture.remove() }

        #expect(throws: SelfUpdateError.assetDigestMismatch) {
            try fixture.updater().install(
                installedVersion: "0.4.0",
                installationPath: fixture.installationPath
            )
        }
        #expect(
            try FileDigest.sha256(of: fixture.installationPath)
                == fixture.originalBinaryDigest
        )
    }

    @Test("Surfaces a bounded network abort")
    func handlesNetworkAbort() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        fixture.transport.fetchFailure = .networkFailure

        #expect(throws: SelfUpdateError.networkFailure) {
            try fixture.updater().check(installedVersion: "0.4.0")
        }
    }

    @Test("Surfaces a network timeout")
    func handlesTimeout() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        fixture.transport.fetchFailure = .timeout

        #expect(throws: SelfUpdateError.timeout) {
            try fixture.updater().check(
                installedVersion: "0.4.0",
                timeout: 0.1
            )
        }
    }

    @Test("Rolls back an activated update after an injected failure")
    func rollsBackFailedActivation() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        let installer = SelfUpdateInstaller(afterActivation: {
            throw InjectedUpdateFailure()
        })

        #expect(throws: SelfUpdateError.installationFailed) {
            try fixture.updater(installer: installer).install(
                installedVersion: "0.4.0",
                installationPath: fixture.installationPath
            )
        }
        #expect(
            try FileDigest.sha256(of: fixture.installationPath)
                == fixture.originalBinaryDigest
        )
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.installationPath.path
            )) == nil
        )
    }

    @Test("Restores the last verified installation manually")
    func manualRollback() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        _ = try fixture.updater().install(
            installedVersion: "0.4.0",
            installationPath: fixture.installationPath
        )

        let result = try fixture.updater().rollback(
            installationPath: fixture.installationPath
        )
        let destination = try FileManager.default
            .destinationOfSymbolicLink(
                atPath: fixture.installationPath.path
            )
        let restored = URL(
            fileURLWithPath: destination,
            relativeTo: fixture.installationPath.deletingLastPathComponent()
        ).standardizedFileURL

        #expect(result.restoredVersion == "0.4.0")
        #expect(result.replacedVersion == "0.4.1")
        #expect(
            try FileDigest.sha256(of: restored)
                == fixture.originalBinaryDigest
        )
    }

    @Test("Refuses a signed downgrade by default")
    func refusesDowngrade() throws {
        let fixture = try SelfUpdateFixture(version: "0.3.9")
        defer { fixture.remove() }

        #expect(
            throws: SelfUpdateError.downgradeRefused(
                installed: "0.4.0",
                requested: "0.3.9"
            )
        ) {
            try fixture.updater().install(
                installedVersion: "0.4.0",
                installationPath: fixture.installationPath
            )
        }
        #expect(!fixture.transport.downloadCalled)
    }

    @Test("Refuses an update requiring a newer macOS")
    func refusesIncompatibleMacOS() throws {
        let fixture = try SelfUpdateFixture(
            version: "0.4.1",
            minimumMacOS: "99.0"
        )
        defer { fixture.remove() }

        #expect(
            throws: SelfUpdateError.incompatibleMacOS(required: "99.0")
        ) {
            try fixture.updater().install(
                installedVersion: "0.4.0",
                installationPath: fixture.installationPath
            )
        }
        #expect(!fixture.transport.downloadCalled)
    }

    @Test("Handles installation paths containing spaces")
    func handlesSpacesInInstallPath() throws {
        let fixture = try SelfUpdateFixture(
            version: "0.4.1",
            installationDirectoryName: "Installed Tools With Spaces"
        )
        defer { fixture.remove() }

        let result = try fixture.updater().install(
            installedVersion: "0.4.0",
            installationPath: fixture.installationPath
        )

        #expect(result.installationPath.contains("Installed Tools With Spaces"))
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.installationPath.path
            )) != nil
        )
    }

    @Test("Refuses an installation directory without write permission")
    func refusesMissingWritePermission() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        let parent = fixture.installationPath.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: parent.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: parent.path
            )
        }

        #expect(throws: SelfUpdateError.installationNotWritable) {
            try fixture.updater().install(
                installedVersion: "0.4.0",
                installationPath: fixture.installationPath
            )
        }
    }

    @Test("Rejects a symbolic-link escape in update management state")
    func rejectsManagementSymlinkEscape() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-ManagementOutside-\(UUID().uuidString)"
            )
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let management = fixture.installationPath
            .deletingLastPathComponent()
            .appendingPathComponent(".sparklekit")
        try FileManager.default.createDirectory(
            at: management,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: management.appendingPathComponent("versions"),
            withDestinationURL: outside
        )

        #expect(throws: SelfUpdateError.unsafeInstallationPath) {
            try fixture.updater().install(
                installedVersion: "0.4.0",
                installationPath: fixture.installationPath
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: outside.path
            ).isEmpty
        )
    }

    @Test("Rejects rollback metadata redirected outside managed storage")
    func rejectsRedirectedRollbackMetadata() throws {
        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        _ = try fixture.updater().install(
            installedVersion: "0.4.0",
            installationPath: fixture.installationPath
        )
        let redirected = fixture.root.appendingPathComponent("Redirected")
        try FileManager.default.createDirectory(
            at: redirected,
            withIntermediateDirectories: true
        )
        let redirectedBinary = redirected.appendingPathComponent("sparklekit")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: redirectedBinary
        )
        let redirectedBundle = redirected.appendingPathComponent(
            SelfUpdateInstaller.resourceBundleName
        )
        try FileManager.default.createDirectory(
            at: redirectedBundle,
            withIntermediateDirectories: true
        )
        try Data("redirected".utf8).write(
            to: redirectedBundle.appendingPathComponent("fixture.txt")
        )

        let stateURL = fixture.installationPath.deletingLastPathComponent()
            .appendingPathComponent(".sparklekit/update-state.json")
        var state = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        var previous = try #require(state["previous"] as? [String: Any])
        previous["binaryPath"] = redirectedBinary.path
        previous["resourceBundlePath"] = redirectedBundle.path
        previous["sha256"] = try FileDigest.sha256(of: redirectedBinary)
        previous["permissions"] = 0o755
        previous["codeSignatureRequired"] = true
        state["previous"] = previous
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: stateURL, options: .atomic)

        #expect(throws: SelfUpdateError.invalidRollback) {
            try fixture.updater().rollback(
                installationPath: fixture.installationPath
            )
        }
        let active = try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.installationPath.path
        )
        #expect(!active.contains("Redirected"))
    }

    @Test("Never executes an unverified downloaded payload")
    func neverExecutesBeforeVerification() throws {
        let markerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-NoExecution-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: markerRoot) }
        try FileManager.default.createDirectory(
            at: markerRoot,
            withIntermediateDirectories: true
        )
        let marker = markerRoot.appendingPathComponent("executed")
        let fixture = try SelfUpdateFixture(
            version: "0.4.1",
            packageScript: """
                #!/bin/sh
                /usr/bin/touch "\(marker.path)"
                """
        )
        defer { fixture.remove() }

        #expect(throws: SelfUpdateError.invalidDownloadedExecutable) {
            try fixture.updater().install(
                installedVersion: "0.4.0",
                installationPath: fixture.installationPath
            )
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Rejects a symbolic-link escape in the downloaded archive")
    func rejectsArchiveSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-UnsafeUpdate-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("SparkleReleaseKit")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("sparklekit"),
            withDestinationURL: outside
        )
        let bundle = package.appendingPathComponent(
            SelfUpdateInstaller.resourceBundleName
        )
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        try Data().write(to: bundle.appendingPathComponent("marker"))
        let archive = root.appendingPathComponent("unsafe.zip")
        let zip = try ProcessRunner().run(
            "/usr/bin/zip",
            arguments: [
                "-y", "-r", archive.path, package.lastPathComponent,
            ],
            directory: root
        )
        try #require(zip.status == 0, Comment(rawValue: zip.standardError))

        #expect(throws: SelfUpdateError.unsafeArchive) {
            try SelfUpdateArchiveExtractor().extract(
                archiveURL: archive,
                to: root.appendingPathComponent("extracted"),
                executablePath: "SparkleReleaseKit/sparklekit",
                resourceBundlePath:
                    "SparkleReleaseKit/\(SelfUpdateInstaller.resourceBundleName)"
            )
        }
    }

    @Test("Uses strict semantic versions and stable-only published metadata")
    func strictSemanticVersionsAndChannels() throws {
        #expect(SemanticVersion("1.2.3") != nil)
        #expect(SemanticVersion("1.2.3-alpha.1") != nil)
        #expect(SemanticVersion("1.2.3-alpha.01") == nil)
        #expect(SemanticVersion("01.2.3") == nil)
        #expect(SemanticVersion("1.2.3+") == nil)
        #expect(SemanticVersion("1.2.3+metadata") == nil)
        #expect(SemanticVersion("1.2.3-alph\u{00E4}") == nil)
        #expect(SemanticVersion("1.2.3-alpha..1") == nil)
        #expect(
            try #require(SemanticVersion("1.2.3-alpha.2"))
                < #require(SemanticVersion("1.2.3-alpha.10"))
        )
        #expect(
            try #require(SemanticVersion("1.2.3-rc.1"))
                < #require(SemanticVersion("1.2.3"))
        )

        let fixture = try SelfUpdateFixture(version: "0.4.1")
        defer { fixture.remove() }
        #expect(throws: SelfUpdateError.unsupportedChannel("beta")) {
            try fixture.updater().check(
                installedVersion: "0.4.0",
                channel: .beta
            )
        }
    }

    @Test("Allows signed HTTPS release-CDN queries only after redirects")
    func releaseCDNRedirectURLPolicy() throws {
        let queriedURL = try #require(
            URL(
                string:
                    "https://release-assets.githubusercontent.com/release.zip?sp=r&sig=signed"
            )
        )

        #expect(throws: SelfUpdateError.unsafeURL) {
            try SelfUpdateURLPolicy.validate(queriedURL)
        }
        try SelfUpdateURLPolicy.validate(
            queriedURL,
            allowRedirectQuery: true
        )

        for unsafe in [
            "http://release-assets.githubusercontent.com/release.zip?sig=signed",
            "https://user:secret@example.test/release.zip?sig=signed",
            "https://example.test/release.zip?sig=signed#fragment",
        ] {
            let url = try #require(URL(string: unsafe))
            #expect(throws: SelfUpdateError.unsafeURL) {
                try SelfUpdateURLPolicy.validate(
                    url,
                    allowRedirectQuery: true
                )
            }
        }
    }

    @Test("Produces deterministic self-update JSON models")
    func stableJSON() throws {
        let result = SelfUpdateCheckResult(
            installedVersion: "0.4.0",
            availableVersion: "0.4.1",
            updateAvailable: true,
            channel: .stable,
            releaseNotes: ["Security hardening"],
            releaseNotesURL:
                "https://github.com/LeonTOfficial/SparkleReleaseKit/releases/tag/v0.4.1",
            sourceCommit: String(repeating: "a", count: 40)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]

        let first = try encoder.encode(result)
        let second = try encoder.encode(result)
        let object = try #require(
            JSONSerialization.jsonObject(with: first) as? [String: Any]
        )

        #expect(first == second)
        #expect(
            Set(object.keys) == [
                "installedVersion", "availableVersion", "updateAvailable",
                "channel", "releaseNotes", "releaseNotesURL", "sourceCommit",
            ]
        )
    }

    @Test("Release manifest generator emits a verifiable detached signature")
    func releaseManifestGenerator() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-ManifestTool-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let asset = root.appendingPathComponent("release.zip")
        let manifest = root.appendingPathComponent("manifest.json")
        let signature = root.appendingPathComponent("manifest.json.sig")
        try Data("release fixture".utf8).write(to: asset)
        let key = Curve25519.Signing.PrivateKey()
        let encodedPrivateKey = key.rawRepresentation.base64EncodedString()
        let repository = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        )
        let script = repository.appendingPathComponent(
            "scripts/create-update-manifest.swift"
        )
        try #require(FileManager.default.fileExists(atPath: script.path))

        let generated = try ProcessRunner().run(
            "/usr/bin/swift",
            arguments: [
                script.path,
                "--version", "0.4.1",
                "--asset", asset.path,
                "--asset-url",
                "https://github.com/LeonTOfficial/SparkleReleaseKit/releases/download/v0.4.1/release.zip",
                "--source-commit", String(repeating: "b", count: 40),
                "--release-notes-url",
                "https://github.com/LeonTOfficial/SparkleReleaseKit/releases/tag/v0.4.1",
                "--note", "Verified release fixture.",
                "--output", manifest.path,
                "--signature-output", signature.path,
            ],
            environment: [
                "SPARKLEKIT_UPDATE_SIGNING_PRIVATE_KEY":
                    encodedPrivateKey
            ],
            timeout: 30
        )

        #expect(generated.status == 0)
        #expect(!generated.standardOutput.contains(encodedPrivateKey))
        #expect(!generated.standardError.contains(encodedPrivateKey))
        let verified = try SelfUpdateManifestVerifier(
            publicKeyBase64:
                key.publicKey.rawRepresentation.base64EncodedString()
        ).verify(
            manifestURL: manifest,
            signatureURL: signature
        )
        let expectedDigest = try FileDigest.sha256(of: asset)
        #expect(verified.version == "0.4.1")
        #expect(verified.asset.sha256 == expectedDigest)
    }

    @Test("Honors the 24-hour update-check preference without telemetry")
    func userUpdatePreference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-Preferences-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let store = UserConfigurationStore(url: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(try store.claimAutomaticUpdateCheck(now: now))
        #expect(
            try !store.claimAutomaticUpdateCheck(
                now: now.addingTimeInterval(23 * 60 * 60)
            )
        )
        #expect(
            try store.claimAutomaticUpdateCheck(
                now: now.addingTimeInterval(24 * 60 * 60)
            )
        )
        _ = try store.setUpdateChecksEnabled(false)
        #expect(
            try !store.claimAutomaticUpdateCheck(
                now: now.addingTimeInterval(48 * 60 * 60)
            )
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

private struct InjectedUpdateFailure: Error {}

private final class FixtureUpdateTransport: SelfUpdateTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    var manifest: Data
    var signature: Data
    let archive: URL
    var fetchFailure: SelfUpdateError?
    private var didDownload = false

    init(manifest: Data, signature: Data, archive: URL) {
        self.manifest = manifest
        self.signature = signature
        self.archive = archive
    }

    var downloadCalled: Bool {
        lock.withLock { didDownload }
    }

    func fetch(
        _ url: URL,
        maximumBytes: Int,
        timeout: TimeInterval
    ) throws -> Data {
        if let fetchFailure { throw fetchFailure }
        let data = url.pathExtension == "sig" ? signature : manifest
        guard data.count <= maximumBytes else {
            throw SelfUpdateError.responseTooLarge
        }
        return data
    }

    func download(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) throws {
        lock.withLock { didDownload = true }
        let size =
            (try FileManager.default.attributesOfItem(atPath: archive.path)[
                .size
            ] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= maximumBytes else {
            throw SelfUpdateError.responseTooLarge
        }
        try FileManager.default.copyItem(at: archive, to: destination)
    }
}

private final class SelfUpdateFixture {
    let root: URL
    let installationPath: URL
    let originalBinaryDigest: String
    let assetBinaryDigest: String
    let transport: FixtureUpdateTransport
    private let publicKey: String
    private let source = SelfUpdateSource(
        manifestURL: URL(string: "https://updates.example.test/manifest.json")!,
        signatureURL: URL(
            string: "https://updates.example.test/manifest.json.sig"
        )!
    )

    init(
        version: String,
        installationDirectoryName: String = "Installed Tools",
        manifestDigest: String? = nil,
        packageScript: String? = nil,
        minimumMacOS: String = "13.0"
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SparkleReleaseKit-SelfUpdate-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let installationDirectory = root.appendingPathComponent(
            installationDirectoryName
        )
        try FileManager.default.createDirectory(
            at: installationDirectory,
            withIntermediateDirectories: true
        )
        installationPath = installationDirectory.appendingPathComponent(
            "sparklekit"
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/false"),
            to: installationPath
        )
        try Self.makeResourceBundle(in: installationDirectory)
        originalBinaryDigest = try FileDigest.sha256(of: installationPath)

        let package = root.appendingPathComponent(
            "Payload/SparkleReleaseKit"
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        let packageBinary = package.appendingPathComponent("sparklekit")
        if let packageScript {
            try packageScript.write(
                to: packageBinary,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: packageBinary.path
            )
        } else {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: packageBinary
            )
        }
        try Self.makeResourceBundle(in: package)
        assetBinaryDigest = try FileDigest.sha256(of: packageBinary)

        let archive = root.appendingPathComponent("sparklekit-macos.zip")
        let zipped = try ProcessRunner().run(
            "/usr/bin/ditto",
            arguments: [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                package.path, archive.path,
            ]
        )
        try #require(
            zipped.status == 0,
            Comment(rawValue: zipped.standardError)
        )
        let archiveAttributes = try FileManager.default.attributesOfItem(
            atPath: archive.path
        )
        let archiveBytes = try #require(
            (archiveAttributes[.size] as? NSNumber)?.int64Value
        )
        let archiveDigest = try FileDigest.sha256(of: archive)
        let manifest = SelfUpdateManifest(
            version: version,
            minimumMacOS: minimumMacOS,
            sourceCommit: String(repeating: "a", count: 40),
            releaseNotesURL:
                "https://github.com/LeonTOfficial/SparkleReleaseKit/releases/tag/v\(version)",
            releaseNotes: ["Verified test update"],
            asset: .init(
                name: archive.lastPathComponent,
                url: "https://updates.example.test/\(archive.lastPathComponent)",
                bytes: archiveBytes,
                sha256: manifestDigest ?? archiveDigest
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        let manifestData = try encoder.encode(manifest)
        let key = Curve25519.Signing.PrivateKey()
        publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let signature = try key.signature(for: manifestData)
            .base64EncodedString()
        transport = FixtureUpdateTransport(
            manifest: manifestData,
            signature: Data((signature + "\n").utf8),
            archive: archive
        )
    }

    func updater(
        installer: SelfUpdateInstaller = .init()
    ) -> SelfUpdater {
        SelfUpdater(
            transport: transport,
            verifier: .init(publicKeyBase64: publicKey),
            installer: installer,
            source: source
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeResourceBundle(in directory: URL) throws {
        let bundle = directory.appendingPathComponent(
            SelfUpdateInstaller.resourceBundleName
        )
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(
            to: bundle.appendingPathComponent("fixture.txt")
        )
    }
}
