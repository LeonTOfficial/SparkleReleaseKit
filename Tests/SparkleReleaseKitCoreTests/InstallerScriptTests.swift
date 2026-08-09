import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("Installer script")
struct InstallerScriptTests {
    @Test("Activates a complete version and supports paths with spaces")
    func installsCompleteVersion() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }

        let result = try fixture.install(version: "0.4.0")

        #expect(result.status == 0)
        #expect(try fixture.installedVersion() == "SparkleReleaseKit 0.4.0 (Sparkle 2.9.5)")
        #expect(try fixture.installedResource() == "resource-0.4.0")
        #expect(try fixture.executablePermissions() & 0o111 != 0)
    }

    @Test("A failure before activation leaves the old installation active")
    func rollsBackBeforeActivation() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        try #require(try fixture.install(version: "0.4.0").status == 0)

        let failed = try fixture.install(version: "0.5.0", failAt: "before-activate")

        #expect(failed.status != 0)
        #expect(try fixture.installedVersion() == "SparkleReleaseKit 0.4.0 (Sparkle 2.9.5)")
        #expect(try fixture.installedResource() == "resource-0.4.0")
    }

    @Test("Migrates a complete legacy flat installation before activation")
    func migratesLegacyInstallation() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        try fixture.seedLegacyInstallation(version: "0.4.0")

        let result = try fixture.install(version: "0.5.0")

        #expect(result.status == 0, Comment(rawValue: result.standardError))
        #expect(try fixture.installedVersion() == "SparkleReleaseKit 0.5.0 (Sparkle 2.9.5)")
        #expect(try fixture.installedResource() == "resource-0.5.0")
    }

    @Test("A failed first installation leaves no public partial installation")
    func cleansUpFailedFirstInstallation() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }

        let failed = try fixture.install(version: "0.5.0", failAt: "before-activate")

        #expect(failed.status != 0)
        #expect(!fixture.hasPublicInstallation())
    }

    @Test("A failure after activation atomically restores the old installation")
    func rollsBackAfterActivation() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        try #require(try fixture.install(version: "0.4.0").status == 0)

        let failed = try fixture.install(version: "0.5.0", failAt: "after-post-validation")

        #expect(failed.status != 0)
        let activeTarget = try fixture.activeTarget()
        #expect(
            try fixture.installedVersion() == "SparkleReleaseKit 0.4.0 (Sparkle 2.9.5)",
            Comment(rawValue: "stderr: \(failed.standardError); active: \(activeTarget)")
        )
        #expect(
            try fixture.installedResource() == "resource-0.4.0",
            Comment(rawValue: "stderr: \(failed.standardError); active: \(activeTarget)")
        )
    }

    @Test("Rejects a concurrent installer without changing the active version")
    func rejectsConcurrentInstaller() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        try #require(try fixture.install(version: "0.4.0").status == 0)
        try fixture.createInstallerLock()

        let failed = try fixture.install(version: "0.5.0")

        #expect(failed.status != 0)
        #expect(failed.standardError.contains("already in progress"))
        #expect(try fixture.installedVersion() == "SparkleReleaseKit 0.4.0 (Sparkle 2.9.5)")
        #expect(try fixture.installedResource() == "resource-0.4.0")
    }
}

private final class InstallerFixture {
    private let manager = FileManager.default
    let root: URL
    let package: URL
    let installDirectory: URL
    private let script: URL
    private let bundleName = "SparkleReleaseKit_SparkleReleaseKitCore.bundle"

    init() throws {
        root = manager.temporaryDirectory.appendingPathComponent(
            "SparkleReleaseKit Installer \(UUID().uuidString)"
        )
        package = root.appendingPathComponent("Package With Spaces")
        installDirectory = root.appendingPathComponent("Install With Spaces")
        script = package.appendingPathComponent("install.sh")
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        try manager.copyItem(
            at: repositoryRoot().appendingPathComponent("scripts/install.sh"),
            to: script
        )
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func remove() {
        try? manager.removeItem(at: root)
    }

    func install(version: String, failAt: String? = nil) throws -> ProcessResult {
        try writePackage(version: version)
        var environment = ["SPARKLEKIT_INSTALL_DIR": installDirectory.path]
        if let failAt { environment["SPARKLEKIT_INSTALL_FAIL_AT"] = failAt }
        return try ProcessRunner().run(
            "/bin/zsh",
            arguments: [script.path],
            environment: environment
        )
    }

    func installedVersion() throws -> String {
        let result = try ProcessRunner().run(
            installDirectory.appendingPathComponent("sparklekit").path,
            arguments: ["version"]
        )
        try #require(result.status == 0, Comment(rawValue: result.standardError))
        return result.standardOutput
    }

    func installedResource() throws -> String {
        try String(
            contentsOf: installDirectory
                .appendingPathComponent(bundleName)
                .appendingPathComponent("resource.txt"),
            encoding: .utf8
        )
    }

    func executablePermissions() throws -> Int {
        let attributes = try manager.attributesOfItem(
            atPath: installDirectory.appendingPathComponent("sparklekit").path
        )
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func activeTarget() throws -> String {
        try manager.destinationOfSymbolicLink(
            atPath: installDirectory.appendingPathComponent(".sparklekit/current").path
        )
    }

    func seedLegacyInstallation(version: String) throws {
        try writePackage(version: version)
        try manager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try manager.copyItem(
            at: package.appendingPathComponent("sparklekit"),
            to: installDirectory.appendingPathComponent("sparklekit")
        )
        try manager.copyItem(
            at: package.appendingPathComponent(bundleName),
            to: installDirectory.appendingPathComponent(bundleName)
        )
    }

    func hasPublicInstallation() -> Bool {
        manager.fileExists(atPath: installDirectory.appendingPathComponent("sparklekit").path)
            || manager.fileExists(atPath: installDirectory.appendingPathComponent(bundleName).path)
    }

    func createInstallerLock() throws {
        try manager.createDirectory(
            at: installDirectory.appendingPathComponent(".sparklekit/install.lock"),
            withIntermediateDirectories: true
        )
    }

    private func writePackage(version: String) throws {
        let binary = package.appendingPathComponent("sparklekit")
        try """
        #!/bin/zsh
        set -e
        [[ "$1" == "version" ]]
        print "SparkleReleaseKit \(version) (Sparkle 2.9.5)"
        """.write(to: binary, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let bundle = package.appendingPathComponent(bundleName)
        try? manager.removeItem(at: bundle)
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "resource-\(version)".write(
            to: bundle.appendingPathComponent("resource.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
