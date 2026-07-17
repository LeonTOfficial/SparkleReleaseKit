import Foundation
import Testing
@testable import SparkleReleaseKitCore

@Suite("Project integration")
struct IntegrationTests {
    @Test("Detects a SwiftUI Xcode project")
    func detectsProject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let detected = try ProjectDetector().detect(at: fixture)

        #expect(detected.appName == "Example App")
        #expect(detected.bundleIdentifier == "com.example.app")
        #expect(detected.minimumMacOS == "13.0")
        #expect(detected.scheme == "Example App")
        #expect(detected.style == .swiftUI)
        #expect(detected.infoPlistURL?.lastPathComponent == "Info.plist")
    }

    @Test("Accepts only GitHub remotes for generated feed metadata")
    func validatesGitHubRemoteHost() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let initialized = try ProcessRunner().run("/usr/bin/git", arguments: ["init"], directory: fixture)
        try #require(initialized.status == 0)
        let added = try ProcessRunner().run(
            "/usr/bin/git",
            arguments: ["remote", "add", "origin", "https://gitlab.com/example/not-github.git"],
            directory: fixture
        )
        try #require(added.status == 0)

        let detected = try ProjectDetector().detect(at: fixture)

        #expect(detected.githubOwner == nil)
        #expect(detected.githubRepository == nil)
    }

    @Test("Rejects a workspace project reference that escapes the project root")
    func rejectsEscapingWorkspaceReference() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let workspace = fixture.appendingPathComponent("Primary.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version="1.0"><FileRef location="group:../Outside.xcodeproj"></FileRef></Workspace>
        """.write(to: workspace.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)

        #expect(throws: ProjectDetectionError.self) {
            try ProjectDetector().detect(at: fixture)
        }
    }

    @Test("Previews without modifying files")
    func dryRun() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = try Integrator().integrate(
            projectRoot: fixture,
            configuration: fixtureConfiguration(),
            apply: false
        )

        #expect(result.applied == false)
        #expect(result.changes.contains { $0.relativePath == "SparkleReleaseKit/AppUpdater.swift" && $0.kind == .create })
        #expect(!FileManager.default.fileExists(atPath: fixture.appendingPathComponent("SparkleReleaseKit/AppUpdater.swift").path))
    }

    @Test("Applies idempotently and patches Info.plist")
    func apply() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let configuration = fixtureConfiguration()

        let first = try Integrator().integrate(projectRoot: fixture, configuration: configuration, apply: true)
        let second = try Integrator().integrate(projectRoot: fixture, configuration: configuration, apply: false)

        #expect(first.applied)
        #expect(first.backupURL != nil)
        #expect(second.changes.allSatisfy { $0.kind == .unchanged })

        let plistURL = fixture.appendingPathComponent("Example App/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["SUFeedURL"] as? String == configuration.updates.feedURL)
        #expect(plist["SUPublicEDKey"] as? String == configuration.updates.publicEDKey)
        #expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".github/workflows/sparkle-release.yml").path))
    }

    @Test("Rejects a generated path that escapes through a symlink")
    func rejectsSymlinkEscape() throws {
        let fixture = try makeFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("SparkleReleaseKitOutside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.appendingPathComponent("SparkleReleaseKit"),
            withDestinationURL: outside
        )

        #expect(throws: IntegrationError.self) {
            try Integrator().integrate(projectRoot: fixture, configuration: fixtureConfiguration(), apply: false)
        }
        #expect(throws: IntegrationError.self) {
            try Integrator().integrate(projectRoot: fixture, configuration: fixtureConfiguration(), apply: true)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("AppUpdater.swift").path))
    }

    @Test("Doctor refuses to read an Info.plist through an escaping symlink")
    func doctorRejectsInfoPlistSymlinkEscape() throws {
        let fixture = try makeFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Outside-Info-\(UUID().uuidString).plist")
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("<plist/>".utf8).write(to: outside)
        let plist = fixture.appendingPathComponent("Example App/Info.plist")
        try FileManager.default.removeItem(at: plist)
        try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: outside)

        let diagnostics = Doctor().inspect(projectRoot: fixture, configuration: fixtureConfiguration())

        #expect(diagnostics.contains { $0.severity == .failure && $0.title == "Info.plist path" })
    }

    @Test("Doctor redacts suspicious tracked-file paths")
    func doctorRedactsSuspiciousTrackedFilePaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sensitiveName = "private_key-production.p8"
        try "not-a-real-key".write(
            to: fixture.appendingPathComponent(sensitiveName),
            atomically: true,
            encoding: .utf8
        )
        let initialized = try ProcessRunner().run("/usr/bin/git", arguments: ["init"], directory: fixture)
        try #require(initialized.status == 0)
        let staged = try ProcessRunner().run("/usr/bin/git", arguments: ["add", sensitiveName], directory: fixture)
        try #require(staged.status == 0)

        let diagnostics = Doctor().inspect(projectRoot: fixture, configuration: fixtureConfiguration())
        let finding = try #require(diagnostics.first { $0.title == "Tracked secret filenames" })

        #expect(finding.severity == .failure)
        #expect(!finding.detail.contains(sensitiveName))
        #expect(finding.detail.contains("intentionally omitted"))
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SparkleReleaseKitTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("Example App.xcodeproj")
        let scheme = project.appendingPathComponent("xcshareddata/xcschemes")
        let sources = root.appendingPathComponent("Example App")
        try FileManager.default.createDirectory(at: scheme, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        try """
        PRODUCT_NAME = "Example App";
        PRODUCT_BUNDLE_IDENTIFIER = com.example.app;
        INFOPLIST_FILE = "Example App/Info.plist";
        """.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try "<Scheme></Scheme>".write(to: scheme.appendingPathComponent("Example App.xcscheme"), atomically: true, encoding: .utf8)
        try "import SwiftUI\n@main struct ExampleApp: App { var body: some Scene { WindowGroup { Text(\"Hello\") } } }"
            .write(to: sources.appendingPathComponent("ExampleApp.swift"), atomically: true, encoding: .utf8)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleName": "Example App",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: sources.appendingPathComponent("Info.plist"))
        return root
    }
}
