import CryptoKit
import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("Release workflow")
struct ReleaseWorkflowTests {
    @Test("Verifies an app archive and prepares a validated appcast", .timeLimit(.minutes(1)))
    func preparesRelease() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        setenv("SRK_TEST_AMBIENT_SECRET", "must-not-reach-helper", 1)
        defer { unsetenv("SRK_TEST_AMBIENT_SECRET") }
        let signingKey = Curve25519.Signing.PrivateKey()
        let tool = try makeFakeGenerateAppcast(
            in: fixture.root,
            archive: fixture.archive,
            signingKey: signingKey
        )
        let configuration = try configurationTrusting(
            tool,
            publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )

        let result = try ReleasePreparer().prepare(
            projectRoot: fixture.root,
            configuration: configuration,
            options: .init(
                version: "1.2.0",
                archiveURL: fixture.archive,
                generateAppcastURL: tool,
                allowProjectExecution: true
            )
        )

        #expect(result.metadata.bundleIdentifier == configuration.app.bundleIdentifier)
        #expect(result.metadata.shortVersion == "1.2.0")
        #expect(FileManager.default.fileExists(atPath: result.archiveURL.path))
        #expect(FileManager.default.fileExists(atPath: result.appcastURL.path))
        #expect(FileManager.default.fileExists(atPath: result.checksumURL.path))
        #expect(FileManager.default.fileExists(atPath: result.manifestURL.path))
        #expect(!result.diagnostics.contains { $0.severity == .failure })
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: result.manifestURL))
        #expect(manifest.sparkleSignatureVerified)
        #expect(manifest.archive == result.archiveURL.lastPathComponent)
        #expect(manifest.sha256.count == 64)
        let stagedDigest = try FileDigest.sha256(of: result.archiveURL)
        #expect(manifest.sha256 == stagedDigest)
        let checksum = try String(contentsOf: result.checksumURL, encoding: .utf8)
        #expect(checksum == "\(manifest.sha256)  \(result.archiveURL.lastPathComponent)\n")
    }

    @Test("Publication preview binds manifest, archive, and checksum", .timeLimit(.minutes(1)))
    func previewsPreparedPublication() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let signingKey = Curve25519.Signing.PrivateKey()
        let tool = try makeFakeGenerateAppcast(
            in: fixture.root,
            archive: fixture.archive,
            signingKey: signingKey
        )
        let configuration = try configurationTrusting(
            tool,
            publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )
        let prepared = try ReleasePreparer().prepare(
            projectRoot: fixture.root,
            configuration: configuration,
            options: .init(
                version: "1.2.0",
                archiveURL: fixture.archive,
                generateAppcastURL: tool,
                allowProjectExecution: true
            )
        )

        let preview = try PublicationPreviewer().preview(
            stageURL: prepared.outputDirectory,
            configuration: configuration
        )
        #expect(preview.repository == "example/example-app")
        #expect(preview.tag == "v1.2.0")
        #expect(preview.assets.contains { $0.name == prepared.archiveURL.lastPathComponent })
        #expect(!preview.diagnostics.contains { $0.severity == .failure })
        #expect(preview.diagnostics.contains { $0.id == "SRK5102" })

        try "0  \(prepared.archiveURL.lastPathComponent)\n".write(
            to: prepared.checksumURL,
            atomically: true,
            encoding: .utf8
        )
        let tampered = try PublicationPreviewer().preview(
            stageURL: prepared.outputDirectory,
            configuration: configuration
        )
        #expect(
            tampered.diagnostics.contains {
                $0.id == "SRK5103"
                    && $0.severity == .failure
                    && $0.affectedComponent == prepared.checksumURL.lastPathComponent
            })
    }

    @Test("Refuses a release version that differs from the app bundle")
    func rejectsVersionMismatch() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tool = try makeFakeGenerateAppcast(
            in: fixture.root,
            archive: fixture.archive,
            signingKey: .init()
        )

        #expect(throws: ReleasePreparationError.self) {
            try ReleasePreparer().prepare(
                projectRoot: fixture.root,
                configuration: try configurationTrusting(tool),
                options: .init(
                    version: "1.3.0",
                    archiveURL: fixture.archive,
                    generateAppcastURL: tool,
                    allowProjectExecution: true
                )
            )
        }
    }

    @Test("Rejects an archive whose symbolic link escapes extraction")
    func rejectsEscapingArchiveSymlink() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SparkleEscape-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let payload = root.appendingPathComponent("Payload")
        let outside = root.appendingPathComponent("Outside.app")
        try manager.createDirectory(at: payload, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            at: payload.appendingPathComponent("Escape.app"),
            withDestinationURL: outside
        )
        let archive = root.appendingPathComponent("Escape.zip")
        let zip = try ProcessRunner().run(
            "/usr/bin/zip",
            arguments: ["-y", "-r", archive.path, payload.lastPathComponent],
            directory: root
        )
        try #require(zip.status == 0, Comment(rawValue: zip.standardError))

        let result = try ReleaseVerifier().inspect(archiveURL: archive)

        #expect(result.diagnostics.contains { $0.severity == .failure && $0.title == "Extracted paths" })
    }

    @Test("Accepts the standard Applications link in a disk image", .timeLimit(.minutes(1)))
    func acceptsStandardApplicationsLinkInDMG() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payload = fixture.root.appendingPathComponent("DMG Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let extract = try ProcessRunner().run(
            "/usr/bin/ditto",
            arguments: ["-x", "-k", fixture.archive.path, payload.path]
        )
        try #require(extract.status == 0, Comment(rawValue: extract.standardError))
        try FileManager.default.createSymbolicLink(
            atPath: payload.appendingPathComponent("Applications").path,
            withDestinationPath: "/Applications"
        )
        let diskImage = fixture.root.appendingPathComponent("Example.App.1.2.0.dmg")
        let create = try ProcessRunner().run(
            "/usr/bin/hdiutil",
            arguments: [
                "create", "-quiet", "-volname", "Example App", "-srcfolder", payload.path, "-ov", "-format", "UDZO", diskImage.path,
            ]
        )
        try #require(create.status == 0, Comment(rawValue: create.standardError))

        let result = try ReleaseVerifier().inspect(archiveURL: diskImage)

        let diagnosticSummary = result.diagnostics
            .map { "[\($0.severity.rawValue)] \($0.title): \($0.detail)" }
            .joined(separator: "\n")
        #expect(
            result.metadata?.bundleIdentifier == "com.example.app",
            Comment(rawValue: diagnosticSummary)
        )
        #expect(!result.diagnostics.contains { $0.severity == .failure && $0.title == "Extracted paths" })
    }

    @Test("Rejects control characters in extracted archive paths")
    func rejectsControlCharactersInArchivePaths() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SparkleControlPath-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let payload = root.appendingPathComponent("Payload")
        try manager.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data().write(to: payload.appendingPathComponent("line\nbreak"))
        let archive = root.appendingPathComponent("Control.zip")
        let zip = try ProcessRunner().run(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", payload.path, archive.path]
        )
        try #require(zip.status == 0, Comment(rawValue: zip.standardError))

        let result = try ReleaseVerifier().inspect(archiveURL: archive)

        #expect(result.diagnostics.contains { $0.severity == .failure && $0.title == "Extracted paths" })
    }

    @Test("Rejects update archives containing multiple main applications")
    func rejectsMultipleApplications() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SparkleMultipleApps-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let payload = root.appendingPathComponent("Payload")
        try manager.createDirectory(at: payload.appendingPathComponent("First.app"), withIntermediateDirectories: true)
        try manager.createDirectory(at: payload.appendingPathComponent("Second.app"), withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("Multiple.zip")
        let zip = try ProcessRunner().run(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", payload.path, archive.path]
        )
        try #require(zip.status == 0, Comment(rawValue: zip.standardError))

        let result = try ReleaseVerifier().inspect(archiveURL: archive)

        #expect(
            result.diagnostics.contains {
                $0.severity == .failure && $0.title == "Application bundle" && $0.detail.contains("multiple")
            })
    }

    @Test("Rejects a hidden second application in an update archive")
    func rejectsHiddenApplication() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SparkleHiddenApp-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let payload = root.appendingPathComponent("Payload")
        try manager.createDirectory(at: payload.appendingPathComponent("Primary.app"), withIntermediateDirectories: true)
        try manager.createDirectory(at: payload.appendingPathComponent(".Hidden.app"), withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("Hidden.zip")
        let zip = try ProcessRunner().run("/usr/bin/ditto", arguments: ["-c", "-k", payload.path, archive.path])
        try #require(zip.status == 0, Comment(rawValue: zip.standardError))

        let result = try ReleaseVerifier().inspect(archiveURL: archive)

        #expect(result.diagnostics.contains { $0.severity == .failure && $0.title == "Application bundle" })
    }

    @Test("Default release staging cannot escape through a project symlink")
    func rejectsEscapingDefaultReleaseStage() throws {
        let fixture = try makeSignedArchive()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("SparkleStageOutside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".sparklekit"),
            withDestinationURL: outside
        )

        #expect(throws: IntegrationError.self) {
            try ReleasePreparer().prepare(
                projectRoot: fixture.root,
                configuration: fixtureConfiguration(),
                options: .init(
                    version: "1.2.0",
                    archiveURL: fixture.archive,
                    generateAppcastURL: fixture.root.appendingPathComponent("generate_appcast")
                )
            )
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: outside.path))?.isEmpty == true)
    }

    @Test("Refuses an executable that impersonates generate_appcast")
    func rejectsWrongGeneratorName() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tool = fixture.root.appendingPathComponent("untrusted-generator")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(throws: GenerateAppcastTrustError.self) {
            try ReleasePreparer().prepare(
                projectRoot: fixture.root,
                configuration: fixtureConfiguration(),
                options: .init(version: "1.2.0", archiveURL: fixture.archive, generateAppcastURL: tool)
            )
        }
    }

    @Test("Accepts ad-hoc signing in free mode and rejects it in Developer ID mode")
    func enforcesReleaseModeSigningPolicy() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let freeResult = try ReleaseVerifier().inspect(
            archiveURL: fixture.archive,
            expectedBundleIdentifier: "com.example.app",
            policy: .free
        )
        #expect(freeResult.artifact?.signingKind == .adHoc)
        #expect(!freeResult.diagnostics.contains { $0.severity == .failure })

        let developerPolicy = try ReleaseVerificationPolicy(
            distribution: .init(releaseMode: .developerID, expectedArchitectures: [])
        )
        let developerResult = try ReleaseVerifier().inspect(
            archiveURL: fixture.archive,
            expectedBundleIdentifier: "com.example.app",
            policy: developerPolicy
        )
        #expect(
            developerResult.diagnostics.contains {
                $0.severity == .failure && $0.title == "Developer ID requirement"
            })
    }

    @Test("Detects ad-hoc signing with Hardened Runtime and Library Validation")
    func detectsLibraryValidationConflict() throws {
        let fixture = try makeSignedArchive(hardenedRuntime: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try ReleaseVerifier().inspect(
            archiveURL: fixture.archive,
            expectedBundleIdentifier: "com.example.app",
            policy: .free
        )

        #expect(
            result.diagnostics.contains {
                $0.id == "SRK2102" && $0.severity == .failure
            })
    }

    @Test("Blocks unsigned applications for release preparation unless explicitly allowed")
    func enforcesUnsignedPreparationPolicy() throws {
        let fixture = try makeSignedArchive(signApp: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let defaultResult = try ReleaseVerifier().inspect(
            archiveURL: fixture.archive,
            expectedBundleIdentifier: "com.example.app",
            policy: .free,
            rejectUnsigned: true
        )
        #expect(
            defaultResult.diagnostics.contains {
                $0.id == "SRK2101" && $0.severity == .failure
            })

        var overridePolicy = ReleaseVerificationPolicy.free
        overridePolicy.allowUnsigned = true
        let overrideResult = try ReleaseVerifier().inspect(
            archiveURL: fixture.archive,
            expectedBundleIdentifier: "com.example.app",
            policy: overridePolicy,
            rejectUnsigned: !overridePolicy.allowUnsigned
        )
        let diagnosticSummary = overrideResult.diagnostics
            .map { "[\($0.severity.rawValue)] \($0.title): \($0.detail)" }
            .joined(separator: "\n")
        #expect(overrideResult.artifact?.signingKind == .unsigned)
        #expect(
            !overrideResult.diagnostics.contains { $0.severity == .failure },
            Comment(rawValue: diagnosticSummary)
        )
        #expect(
            overrideResult.diagnostics.contains {
                $0.id == "SRK2101" && $0.severity == .warning
            })
    }

    @Test("Reports an invalid nested signature precisely")
    func detectsInvalidNestedSignature() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payload = fixture.root.appendingPathComponent("Tampered")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let extract = try ProcessRunner().run(
            "/usr/bin/ditto",
            arguments: ["-x", "-k", fixture.archive.path, payload.path]
        )
        try #require(extract.status == 0, Comment(rawValue: extract.standardError))
        let frameworkBinary = payload.appendingPathComponent(
            "Example App.app/Contents/Frameworks/Sparkle.framework/Versions/A/Sparkle"
        )
        let handle = try FileHandle(forWritingTo: frameworkBinary)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let tampered = fixture.root.appendingPathComponent("Tampered.zip")
        let zip = try ProcessRunner().run(
            "/usr/bin/ditto",
            arguments: [
                "-c", "-k", "--keepParent",
                payload.appendingPathComponent("Example App.app").path,
                tampered.path,
            ]
        )
        try #require(zip.status == 0, Comment(rawValue: zip.standardError))

        let result = try ReleaseVerifier().inspect(
            archiveURL: tampered,
            expectedBundleIdentifier: "com.example.app",
            policy: .free
        )

        #expect(
            result.diagnostics.contains {
                $0.id == "SRK2103"
                    && $0.severity == .failure
                    && $0.affectedComponent?.contains("Sparkle.framework") == true
            })
    }

    @Test(
        "Runs the complete secure maintenance lifecycle on a minimal app",
        .timeLimit(.minutes(1))
    )
    func secureMaintenanceEndToEnd() throws {
        let oldApp = try makeSignedArchive(
            shortVersion: "1.1.0",
            buildVersion: "110"
        )
        let newApp = try makeSignedArchive()
        defer {
            try? FileManager.default.removeItem(at: oldApp.root)
            try? FileManager.default.removeItem(at: newApp.root)
        }
        let signingKey = Curve25519.Signing.PrivateKey()
        let tool = try makeFakeGenerateAppcast(
            in: newApp.root,
            archive: newApp.archive,
            signingKey: signingKey
        )
        let configuration = try configurationTrusting(
            tool,
            publicKey:
                signingKey.publicKey.rawRepresentation.base64EncodedString()
        )

        let oldInspection = try ReleaseVerifier().inspect(
            archiveURL: oldApp.archive,
            expectedBundleIdentifier: configuration.app.bundleIdentifier
        )
        let newInspection = try ReleaseVerifier().inspect(
            archiveURL: newApp.archive,
            expectedBundleIdentifier: configuration.app.bundleIdentifier
        )
        #expect(oldInspection.metadata?.shortVersion == "1.1.0")
        #expect(newInspection.metadata?.shortVersion == "1.2.0")
        #expect(
            !newInspection.diagnostics.contains {
                $0.severity == .failure
            }
        )

        let interruptedTool = newApp.root.appendingPathComponent(
            "Interrupted/generate_appcast"
        )
        try FileManager.default.createDirectory(
            at: interruptedTool.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 73\n".write(
            to: interruptedTool,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: interruptedTool.path
        )
        var interruptedConfiguration = configuration
        interruptedConfiguration.tools.generateAppcast.allowedSHA256 = [
            try FileDigest.sha256(of: interruptedTool)
        ]
        let interruptedOutput = newApp.root.appendingPathComponent(
            "Interrupted Release"
        )
        #expect(throws: ReleasePreparationError.self) {
            try ReleasePreparer().prepare(
                projectRoot: newApp.root,
                configuration: interruptedConfiguration,
                options: .init(
                    version: "1.2.0",
                    archiveURL: newApp.archive,
                    outputRootURL: interruptedOutput,
                    generateAppcastURL: interruptedTool,
                    allowProjectExecution: true
                )
            )
        }
        let interruptedContents =
            (try? FileManager.default.contentsOfDirectory(
                atPath: interruptedOutput.path
            )) ?? []
        #expect(
            !interruptedContents.contains {
                $0.hasPrefix(".preparing-")
            }
        )

        let prepared = try ReleasePreparer().prepare(
            projectRoot: newApp.root,
            configuration: configuration,
            options: .init(
                version: "1.2.0",
                archiveURL: newApp.archive,
                generateAppcastURL: tool,
                allowProjectExecution: true
            )
        )
        let appcast = try AppcastValidator().validate(
            fileURL: prepared.appcastURL
        )
        let signature = try UpdateSignatureVerifier().verify(
            archiveURL: prepared.archiveURL,
            appcast: appcast,
            publicEDKey: configuration.updates.publicEDKey,
            expectedBuildVersion: "120"
        )
        #expect(signature.severity == .pass)

        let invalidAppcastURL = newApp.root.appendingPathComponent(
            "invalid-appcast.xml"
        )
        var invalidAppcast = try String(
            contentsOf: prepared.appcastURL,
            encoding: .utf8
        )
        let validSignature = try #require(
            appcast.enclosures.first?.signature
        )
        invalidAppcast = invalidAppcast.replacingOccurrences(
            of: validSignature,
            with: Data(repeating: 4, count: 64).base64EncodedString()
        )
        try invalidAppcast.write(
            to: invalidAppcastURL,
            atomically: true,
            encoding: .utf8
        )
        let structurallyValidButWrong = try AppcastValidator().validate(
            fileURL: invalidAppcastURL
        )
        #expect(throws: UpdateSignatureVerificationError.invalidSignature) {
            try UpdateSignatureVerifier().verify(
                archiveURL: prepared.archiveURL,
                appcast: structurallyValidButWrong,
                publicEDKey: configuration.updates.publicEDKey,
                expectedBuildVersion: "120"
            )
        }

        let tampered = newApp.root.appendingPathComponent("tampered.zip")
        try FileManager.default.copyItem(
            at: prepared.archiveURL,
            to: tampered
        )
        let tamperedHandle = try FileHandle(forWritingTo: tampered)
        try tamperedHandle.seekToEnd()
        try tamperedHandle.write(contentsOf: Data([0x41]))
        try tamperedHandle.close()
        var tamperedAppcast = appcast
        tamperedAppcast.enclosures[0].url =
            "https://example.test/\(tampered.lastPathComponent)"
        #expect(throws: UpdateSignatureVerificationError.self) {
            try UpdateSignatureVerifier().verify(
                archiveURL: tampered,
                appcast: tamperedAppcast,
                publicEDKey: configuration.updates.publicEDKey,
                expectedBuildVersion: "120"
            )
        }

        let wrongBundle = try ReleaseVerifier().inspect(
            archiveURL: newApp.archive,
            expectedBundleIdentifier: "com.example.wrong"
        )
        #expect(
            wrongBundle.diagnostics.contains {
                $0.severity == .failure
                    && $0.title == "Bundle identifier"
            }
        )
        #expect(throws: ReleasePreparationError.self) {
            try ReleasePreparer().prepare(
                projectRoot: newApp.root,
                configuration: configuration,
                options: .init(
                    version: "1.3.0",
                    archiveURL: newApp.archive,
                    generateAppcastURL: tool,
                    allowProjectExecution: true
                )
            )
        }

        let freeResult = try ReleaseVerifier().inspect(
            archiveURL: newApp.archive,
            expectedBundleIdentifier: configuration.app.bundleIdentifier,
            policy: .free
        )
        let developerResult = try ReleaseVerifier().inspect(
            archiveURL: newApp.archive,
            expectedBundleIdentifier: configuration.app.bundleIdentifier,
            policy: try ReleaseVerificationPolicy(
                distribution: .init(
                    releaseMode: .developerID,
                    expectedArchitectures: []
                )
            )
        )
        #expect(
            !freeResult.diagnostics.contains {
                $0.severity == .failure
            }
        )
        #expect(
            developerResult.diagnostics.contains {
                $0.severity == .failure
                    && $0.title == "Developer ID requirement"
            }
        )

        let projectInfo = newApp.root.appendingPathComponent(
            "Example App/Info.plist"
        )
        try FileManager.default.createDirectory(
            at: projectInfo.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: newApp.root.appendingPathComponent(
                "build/Example App.app/Contents/Info.plist"
            ),
            to: projectInfo
        )
        _ = try Integrator().integrate(
            projectRoot: newApp.root,
            configuration: configuration,
            apply: true
        )
        let managedNotes = newApp.root.appendingPathComponent(
            "release-notes/next.md"
        )
        try FileManager.default.removeItem(at: managedNotes)
        let migration = try ProjectUpgrader().upgrade(
            projectRoot: newApp.root,
            apply: true
        )
        #expect(migration.applied)
        #expect(FileManager.default.fileExists(atPath: managedNotes.path))

        let toolInstall = newApp.root.appendingPathComponent(
            "Self Update/bin"
        )
        let package = newApp.root.appendingPathComponent(
            "Self Update/package"
        )
        try FileManager.default.createDirectory(
            at: toolInstall,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        let installedCLI = toolInstall.appendingPathComponent("sparklekit")
        let packageCLI = package.appendingPathComponent("sparklekit")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/false"),
            to: installedCLI
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: packageCLI
        )
        let bundleName = SelfUpdateInstaller.resourceBundleName
        let installedBundle = toolInstall.appendingPathComponent(bundleName)
        let packageBundle = package.appendingPathComponent(bundleName)
        try FileManager.default.createDirectory(
            at: installedBundle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: packageBundle,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: installedBundle.appendingPathComponent("fixture")
        )
        try Data("new".utf8).write(
            to: packageBundle.appendingPathComponent("fixture")
        )
        let originalCLIDigest = try FileDigest.sha256(of: installedCLI)
        let updateResult = try SelfUpdateInstaller().install(
            packageExecutable: packageCLI,
            packageResourceBundle: packageBundle,
            newVersion: "0.4.1",
            installedVersion: "0.4.0",
            installationPath: installedCLI
        )
        #expect(updateResult.installedVersion == "0.4.1")
        let rollback = try SelfUpdateInstaller().rollback(
            installationPath: installedCLI
        )
        let restoredTarget = try FileManager.default
            .destinationOfSymbolicLink(atPath: installedCLI.path)
        let restoredURL = URL(
            fileURLWithPath: restoredTarget,
            relativeTo: installedCLI.deletingLastPathComponent()
        ).standardizedFileURL
        #expect(rollback.restoredVersion == "0.4.0")
        #expect(try FileDigest.sha256(of: restoredURL) == originalCLIDigest)
        #expect(SemanticVersion("0.3.9")! < SemanticVersion("0.4.0")!)
    }

    private func makeSignedArchive(
        hardenedRuntime: Bool = false,
        signApp: Bool = true,
        shortVersion: String = "1.2.0",
        buildVersion: String = "120"
    ) throws -> (root: URL, archive: URL) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SparkleRelease-\(UUID().uuidString)")
        let app = root.appendingPathComponent("build/Example App.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try manager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try manager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Example App"))

        let plist: [String: Any] = [
            "CFBundleExecutable": "Example App",
            "CFBundleIdentifier": "com.example.app",
            "CFBundleName": "Example App",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": buildVersion,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))

        let framework = frameworks.appendingPathComponent("Sparkle.framework")
        let frameworkBinary = framework.appendingPathComponent("Versions/A/Sparkle")
        let frameworkResources = framework.appendingPathComponent("Versions/A/Resources")
        try manager.createDirectory(at: frameworkResources, withIntermediateDirectories: true)
        try manager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: frameworkBinary)
        let frameworkPlist: [String: Any] = [
            "CFBundleExecutable": "Sparkle",
            "CFBundleIdentifier": "org.sparkle-project.Sparkle",
            "CFBundleName": "Sparkle",
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "2.9.4",
            "CFBundleVersion": "2.9.4",
        ]
        let frameworkData = try PropertyListSerialization.data(fromPropertyList: frameworkPlist, format: .xml, options: 0)
        try frameworkData.write(to: frameworkResources.appendingPathComponent("Info.plist"))
        try manager.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try manager.createSymbolicLink(
            atPath: framework.appendingPathComponent("Sparkle").path, withDestinationPath: "Versions/Current/Sparkle")
        try manager.createSymbolicLink(
            atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")

        let frameworkSign = try ProcessRunner().run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", framework.path])
        try #require(frameworkSign.status == 0, Comment(rawValue: frameworkSign.standardError))
        if signApp {
            var arguments = ["--force", "--sign", "-"]
            if hardenedRuntime {
                arguments += ["--options", "runtime"]
            }
            arguments.append(app.path)
            let appSign = try ProcessRunner().run(
                "/usr/bin/codesign",
                arguments: arguments
            )
            try #require(appSign.status == 0, Comment(rawValue: appSign.standardError))
        } else {
            let executableUnsign = try ProcessRunner().run(
                "/usr/bin/codesign",
                arguments: [
                    "--remove-signature",
                    macOS.appendingPathComponent("Example App").path,
                ]
            )
            try #require(
                executableUnsign.status == 0,
                Comment(rawValue: executableUnsign.standardError)
            )
        }

        let archive = root.appendingPathComponent(
            "Example.App.\(shortVersion).zip"
        )
        let zip = try ProcessRunner().run("/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", app.path, archive.path])
        try #require(zip.status == 0, Comment(rawValue: zip.standardError))
        return (root, archive)
    }

    private func makeFakeGenerateAppcast(
        in root: URL,
        archive: URL,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> URL {
        let url = root.appendingPathComponent("generate_appcast")
        let archiveData = try Data(contentsOf: archive, options: [.mappedIfSafe])
        let signature = try signingKey.signature(for: archiveData).base64EncodedString()
        let script = #"""
            #!/bin/sh
            set -eu
            if [ -n "${SRK_TEST_AMBIENT_SECRET:-}" ]; then
              echo "ambient secret reached helper" >&2
              exit 91
            fi
            stage=""
            for argument in "$@"; do stage="$argument"; done
            archive="$(find "$stage" -maxdepth 1 -name '*.zip' -print -quit)"
            name="$(basename "$archive")"
            length="$(stat -f '%z' "$archive")"
            cat > "$stage/appcast.xml" <<XML
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><title>Example updates</title><item><title>1.2.0</title>
                <enclosure url="https://github.com/example/example-app/releases/download/v1.2.0/$name" sparkle:version="120" length="$length" sparkle:edSignature="\#(signature)" />
              </item></channel>
            </rss>
            XML
            """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func configurationTrusting(
        _ tool: URL,
        publicKey: String = Data(repeating: 7, count: 32).base64EncodedString()
    ) throws -> SparkleKitConfiguration {
        var configuration = fixtureConfiguration(publicKey: publicKey)
        configuration.tools.generateAppcast = .init(
            requireValidSignature: false,
            allowedSHA256: [try FileDigest.sha256(of: tool)]
        )
        return configuration
    }
}
