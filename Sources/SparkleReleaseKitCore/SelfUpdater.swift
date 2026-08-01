import Foundation

public struct SelfUpdateSource: Equatable, Sendable {
    public var manifestURL: URL
    public var signatureURL: URL
    public var channel: SelfUpdateChannel

    public static let stable = SelfUpdateSource(
        manifestURL: URL(
            string:
                "https://github.com/LeonTOfficial/SparkleReleaseKit/releases/latest/download/sparklekit-update-manifest.json"
        )!,
        signatureURL: URL(
            string:
                "https://github.com/LeonTOfficial/SparkleReleaseKit/releases/latest/download/sparklekit-update-manifest.json.sig"
        )!,
        channel: .stable
    )

    public init(
        manifestURL: URL,
        signatureURL: URL,
        channel: SelfUpdateChannel = .stable
    ) {
        self.manifestURL = manifestURL
        self.signatureURL = signatureURL
        self.channel = channel
    }
}

public struct SelfUpdater: Sendable {
    private static let maximumManifestBytes = 1_024 * 1_024
    private static let maximumSignatureBytes = 4 * 1_024
    private static let maximumAssetBytes: Int64 = 256 * 1_024 * 1_024

    private let transport: any SelfUpdateTransport
    private let verifier: SelfUpdateManifestVerifier
    private let installer: SelfUpdateInstaller
    private let source: SelfUpdateSource

    public init(
        transport: any SelfUpdateTransport = HTTPSUpdateTransport(),
        verifier: SelfUpdateManifestVerifier = .init(),
        installer: SelfUpdateInstaller = .init(),
        source: SelfUpdateSource = .stable
    ) {
        self.transport = transport
        self.verifier = verifier
        self.installer = installer
        self.source = source
    }

    public func check(
        installedVersion: String,
        channel: SelfUpdateChannel = .stable,
        timeout: TimeInterval = 10
    ) throws -> SelfUpdateCheckResult {
        let installed = try parsedInstalledVersion(installedVersion)
        let manifest = try loadManifest(channel: channel, timeout: timeout)
        guard let available = SemanticVersion(manifest.version) else {
            throw SelfUpdateError.unsupportedManifest
        }
        return SelfUpdateCheckResult(
            installedVersion: installed.description,
            availableVersion: available.description,
            updateAvailable: available > installed,
            channel: manifest.channel,
            releaseNotes: manifest.releaseNotes,
            releaseNotesURL: manifest.releaseNotesURL,
            sourceCommit: manifest.sourceCommit
        )
    }

    public func install(
        installedVersion: String,
        installationPath: URL,
        channel: SelfUpdateChannel = .stable,
        allowDowngrade: Bool = false,
        timeout: TimeInterval = 30
    ) throws -> SelfUpdateInstallResult {
        let installed = try parsedInstalledVersion(installedVersion)
        let manifest = try loadManifest(channel: channel, timeout: timeout)
        guard let available = SemanticVersion(manifest.version),
            let assetURL = URL(string: manifest.asset.url)
        else {
            throw SelfUpdateError.unsupportedManifest
        }
        try validateMinimumMacOS(manifest.minimumMacOS)
        if available == installed {
            throw SelfUpdateError.noUpdateAvailable
        }
        if available < installed, !allowDowngrade {
            throw SelfUpdateError.downgradeRefused(
                installed: installed.description,
                requested: available.description
            )
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-SelfUpdate-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporary.path
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let archive = temporary.appendingPathComponent(manifest.asset.name)
        try transport.download(
            assetURL,
            to: archive,
            maximumBytes: min(
                manifest.asset.bytes,
                Self.maximumAssetBytes
            ),
            timeout: timeout
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: archive.path
        )
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard bytes == manifest.asset.bytes else {
            throw SelfUpdateError.assetSizeMismatch
        }
        guard
            try FileDigest.sha256(of: archive)
                == manifest.asset.sha256
        else {
            throw SelfUpdateError.assetDigestMismatch
        }

        let extracted = try SelfUpdateArchiveExtractor().extract(
            archiveURL: archive,
            to: temporary.appendingPathComponent("extracted"),
            executablePath: manifest.asset.executablePath,
            resourceBundlePath: manifest.asset.resourceBundlePath
        )
        try verifyDownloadedExecutable(extracted.executable)
        return try installer.install(
            packageExecutable: extracted.executable,
            packageResourceBundle: extracted.resourceBundle,
            newVersion: available.description,
            installedVersion: installed.description,
            installationPath: installationPath
        )
    }

    public func rollback(
        installationPath: URL
    ) throws -> SelfUpdateRollbackResult {
        try installer.rollback(installationPath: installationPath)
    }

    private func loadManifest(
        channel: SelfUpdateChannel,
        timeout: TimeInterval
    ) throws -> SelfUpdateManifest {
        guard source.channel == channel else {
            throw SelfUpdateError.unsupportedChannel(channel.rawValue)
        }
        let manifest = try transport.fetch(
            source.manifestURL,
            maximumBytes: Self.maximumManifestBytes,
            timeout: timeout
        )
        let signature = try transport.fetch(
            source.signatureURL,
            maximumBytes: Self.maximumSignatureBytes,
            timeout: timeout
        )
        return try verifier.verify(
            manifestData: manifest,
            signatureData: signature,
            expectedChannel: channel
        )
    }

    private func parsedInstalledVersion(
        _ value: String
    ) throws -> SemanticVersion {
        guard let version = SemanticVersion(value) else {
            throw SelfUpdateError.invalidInstalledVersion
        }
        return version
    }

    private func verifyDownloadedExecutable(_ executable: URL) throws {
        let result = try ProcessRunner().run(
            "/usr/bin/codesign",
            arguments: [
                "--verify", "--strict", "--verbose=2", executable.path,
            ],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            inheritEnvironment: false,
            timeout: 30
        )
        guard result.status == 0,
            !result.timedOut,
            !result.standardOutputTruncated,
            !result.standardErrorTruncated
        else {
            throw SelfUpdateError.invalidDownloadedExecutable
        }
    }

    private func validateMinimumMacOS(_ value: String) throws {
        let required = value.split(separator: ".").compactMap {
            Int($0)
        }
        guard required.count >= 2 else {
            throw SelfUpdateError.unsupportedManifest
        }
        let currentValue = ProcessInfo.processInfo.operatingSystemVersion
        let current = [
            currentValue.majorVersion,
            currentValue.minorVersion,
            currentValue.patchVersion,
        ]
        let paddedRequired =
            required
            + Array(
                repeating: 0,
                count: max(0, current.count - required.count)
            )
        if current.lexicographicallyPrecedes(paddedRequired) {
            throw SelfUpdateError.incompatibleMacOS(required: value)
        }
    }
}
