import Foundation
import Testing
@testable import SparkleReleaseKitCore

@Suite("Release workflow")
struct ReleaseWorkflowTests {
    @Test("Verifies an app archive and prepares a validated appcast", .timeLimit(.minutes(1)))
    func preparesRelease() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tool = try makeFakeGenerateAppcast(in: fixture.root)
        let configuration = fixtureConfiguration()

        let result = try ReleasePreparer().prepare(
            projectRoot: fixture.root,
            configuration: configuration,
            options: .init(
                version: "1.2.0",
                archiveURL: fixture.archive,
                generateAppcastURL: tool
            )
        )

        #expect(result.metadata.bundleIdentifier == configuration.app.bundleIdentifier)
        #expect(result.metadata.shortVersion == "1.2.0")
        #expect(FileManager.default.fileExists(atPath: result.archiveURL.path))
        #expect(FileManager.default.fileExists(atPath: result.appcastURL.path))
        #expect(!result.diagnostics.contains { $0.severity == .failure })
    }

    @Test("Refuses a release version that differs from the app bundle")
    func rejectsVersionMismatch() throws {
        let fixture = try makeSignedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: ReleasePreparationError.self) {
            try ReleasePreparer().prepare(
                projectRoot: fixture.root,
                configuration: fixtureConfiguration(),
                options: .init(version: "1.3.0", archiveURL: fixture.archive)
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
            arguments: ["create", "-quiet", "-volname", "Example App", "-srcfolder", payload.path, "-ov", "-format", "UDZO", diskImage.path]
        )
        try #require(create.status == 0, Comment(rawValue: create.standardError))

        let result = try ReleaseVerifier().inspect(archiveURL: diskImage)

        #expect(result.metadata?.bundleIdentifier == "com.example.app")
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

        #expect(result.diagnostics.contains {
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

        #expect(throws: ReleasePreparationError.self) {
            try ReleasePreparer().prepare(
                projectRoot: fixture.root,
                configuration: fixtureConfiguration(),
                options: .init(version: "1.2.0", archiveURL: fixture.archive, generateAppcastURL: tool)
            )
        }
    }

    private func makeSignedArchive() throws -> (root: URL, archive: URL) {
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
            "CFBundleShortVersionString": "1.2.0",
            "CFBundleVersion": "120",
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
        try manager.createSymbolicLink(atPath: framework.appendingPathComponent("Sparkle").path, withDestinationPath: "Versions/Current/Sparkle")
        try manager.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")

        let frameworkSign = try ProcessRunner().run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", framework.path])
        try #require(frameworkSign.status == 0, Comment(rawValue: frameworkSign.standardError))
        let appSign = try ProcessRunner().run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path])
        try #require(appSign.status == 0, Comment(rawValue: appSign.standardError))

        let archive = root.appendingPathComponent("Example.App.1.2.0.zip")
        let zip = try ProcessRunner().run("/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", app.path, archive.path])
        try #require(zip.status == 0, Comment(rawValue: zip.standardError))
        return (root, archive)
    }

    private func makeFakeGenerateAppcast(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("generate_appcast")
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let script = #"""
        #!/bin/sh
        set -eu
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
}
