import CryptoKit
import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("Managed project upgrades")
struct ProjectUpgraderTests {
    @Test("Recognizes unchanged generated files")
    func unchangedGeneratedFiles() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }

        let result = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: false
        )

        #expect(result.conflicts.isEmpty)
        #expect(
            result.changes.first {
                $0.relativePath == "SparkleReleaseKit/AppUpdater.swift"
            }?.kind == .unchanged
        )
        #expect(!result.applied)
    }

    @Test("Updates a provably unchanged older generated template")
    func updatesRecordedOldTemplate() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        let updaterPath = "SparkleReleaseKit/AppUpdater.swift"
        let updater = fixture.root.appendingPathComponent(updaterPath)
        let legacy = Data("// legacy generated template\n".utf8)
        try legacy.write(to: updater, options: .atomic)
        try fixture.recordManifestHash(
            UpgradeProjectFixture.sha256(legacy),
            for: updaterPath
        )
        try fixture.recordConfigurationHash(
            UpgradeProjectFixture.sha256(legacy),
            for: updaterPath
        )

        let preview = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: false
        )
        let applied = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: true
        )

        #expect(preview.conflicts.isEmpty)
        #expect(
            preview.changes.first { $0.relativePath == updaterPath }?.kind
                == .update
        )
        #expect(
            preview.changes.first { $0.relativePath == updaterPath }?.diff?
                .contains("-// legacy generated template") == true
        )
        #expect(applied.applied)
        #expect(try Data(contentsOf: updater) != legacy)
        #expect(applied.backupPath != nil)
    }

    @Test("Preserves a manually changed managed file as a conflict")
    func manualEditConflict() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        let updater = fixture.root.appendingPathComponent(
            "SparkleReleaseKit/AppUpdater.swift"
        )
        let original = try Data(contentsOf: updater)
        try Data("// Leon's custom integration\n".utf8).write(
            to: updater,
            options: .atomic
        )

        let result = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: true
        )

        #expect(!result.applied)
        #expect(result.conflicts.count == 1)
        #expect(
            result.conflicts.first?.relativePath
                == "SparkleReleaseKit/AppUpdater.swift"
        )
        #expect(try Data(contentsOf: updater) != original)
        #expect(
            try String(contentsOf: updater, encoding: .utf8)
                == "// Leon's custom integration\n"
        )
    }

    @Test("Redacts sensitive values from conflict previews")
    func redactsSensitiveConflictDiff() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        let updater = fixture.root.appendingPathComponent(
            "SparkleReleaseKit/AppUpdater.swift"
        )
        try Data("let apiToken = \"DO_NOT_PRINT\"\n".utf8).write(
            to: updater,
            options: .atomic
        )

        let result = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: false
        )
        let conflict = try #require(result.conflicts.first)

        #expect(conflict.diff?.contains("[redacted potentially sensitive line]") == true)
        #expect(conflict.diff?.contains("DO_NOT_PRINT") == false)
    }

    @Test("Treats inconsistent ownership hashes as a conflict")
    func inconsistentOwnershipMetadata() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        let updaterPath = "SparkleReleaseKit/AppUpdater.swift"
        let updater = fixture.root.appendingPathComponent(updaterPath)
        let legacy = Data("// legacy generated template\n".utf8)
        try legacy.write(to: updater, options: .atomic)
        try fixture.recordManifestHash(
            UpgradeProjectFixture.sha256(legacy),
            for: updaterPath
        )

        let result = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: true
        )

        #expect(!result.applied)
        #expect(result.conflicts.count == 1)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.reason.contains("metadata disagrees"))
        #expect(try Data(contentsOf: updater) == legacy)
    }

    @Test("Rejects duplicate ownership entries")
    func duplicateOwnershipEntries() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        try fixture.duplicateFirstManifestEntry()

        #expect(throws: ConfigurationError.self) {
            try ProjectUpgrader().upgrade(
                projectRoot: fixture.root,
                apply: false
            )
        }
    }

    @Test("Previews and repairs a partially integrated project")
    func partiallyIntegratedProject() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent(
            "SparkleReleaseKit/INTEGRATION.md"
        )
        try FileManager.default.removeItem(at: missing)
        try FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent(
                ".sparklekit/manifest.json"
            )
        )

        let preview = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: false
        )
        let applied = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: true
        )

        #expect(preview.conflicts.isEmpty)
        #expect(
            preview.changes.first {
                $0.relativePath == "SparkleReleaseKit/INTEGRATION.md"
            }?.kind == .create
        )
        #expect(applied.applied)
        #expect(FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("Migrates an older configuration schema in a controlled preview")
    func oldSchemaVersion() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        try fixture.makeConfigurationLegacy(schemaVersion: 3)
        let before = try Data(contentsOf: fixture.configurationURL)

        let preview = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: false
        )

        #expect(preview.fromSchemaVersion == 3)
        #expect(
            preview.toSchemaVersion
                == SparkleKitConfiguration.currentSchemaVersion
        )
        #expect(!preview.applied)
        #expect(try Data(contentsOf: fixture.configurationURL) == before)
        #expect(
            preview.changes.first {
                $0.relativePath == ConfigurationStore.defaultFileName
            }?.kind == .update
        )
    }

    @Test("Restores a missing managed file")
    func missingManagedFile() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent(
            "release-notes/next.md"
        )
        try FileManager.default.removeItem(at: missing)

        let result = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: true
        )

        #expect(result.applied)
        #expect(FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("Leaves unknown additional project files untouched")
    func preservesUnknownAdditionalFiles() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        let custom = fixture.root.appendingPathComponent(
            "SparkleReleaseKit/CustomHooks.swift"
        )
        let content = Data("let customHook = true\n".utf8)
        try content.write(to: custom)
        try fixture.makeConfigurationLegacy(schemaVersion: 3)

        _ = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: true
        )

        #expect(try Data(contentsOf: custom) == content)
    }

    @Test("Rejects a managed-file symbolic-link escape")
    func rejectsSymlinkEscape() throws {
        let fixture = try UpgradeProjectFixture()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-Outside-\(UUID().uuidString)"
            )
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside)
        let updater = fixture.root.appendingPathComponent(
            "SparkleReleaseKit/AppUpdater.swift"
        )
        try FileManager.default.removeItem(at: updater)
        try FileManager.default.createSymbolicLink(
            at: updater,
            withDestinationURL: outside
        )

        #expect(throws: IntegrationError.self) {
            try ProjectUpgrader().upgrade(
                projectRoot: fixture.root,
                apply: false
            )
        }
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test("Rejects a configured write outside the project")
    func rejectsOutsideWrite() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.configurationURL)
            ) as? [String: Any]
        )
        var project = try #require(object["project"] as? [String: Any])
        project["infoPlist"] = "../Outside/Info.plist"
        object["project"] = project
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: fixture.configurationURL, options: .atomic)

        #expect(throws: ConfigurationError.self) {
            try ProjectUpgrader().upgrade(
                projectRoot: fixture.root,
                apply: true
            )
        }
    }

    @Test("Rolls every write back after an injected migration failure")
    func transactionalRollback() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        try fixture.makeConfigurationLegacy(schemaVersion: 3)
        let missing = fixture.root.appendingPathComponent(
            "release-notes/next.md"
        )
        try FileManager.default.removeItem(at: missing)
        let originalConfiguration = try Data(
            contentsOf: fixture.configurationURL
        )
        let upgrader = ProjectUpgrader { count, _ in
            if count == 2 { throw InjectedMigrationFailure() }
        }

        #expect(throws: InjectedMigrationFailure.self) {
            try upgrader.upgrade(
                projectRoot: fixture.root,
                apply: true
            )
        }

        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(
            try Data(contentsOf: fixture.configurationURL)
                == originalConfiguration
        )
    }

    @Test("A second successful migration is idempotent")
    func idempotentSecondRun() throws {
        let fixture = try UpgradeProjectFixture()
        defer { fixture.remove() }
        try fixture.makeConfigurationLegacy(schemaVersion: 3)

        let first = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: true
        )
        let second = try ProjectUpgrader().upgrade(
            projectRoot: fixture.root,
            apply: true
        )

        #expect(first.applied)
        #expect(!second.applied)
        #expect(second.conflicts.isEmpty)
        #expect(
            second.changes.allSatisfy {
                $0.kind == .unchanged || $0.kind == .preserved
            }
        )
    }
}

private struct InjectedMigrationFailure: Error {}

private final class UpgradeProjectFixture {
    let root: URL
    let configurationURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SparkleReleaseKit-Upgrade-\(UUID().uuidString)"
        )
        let appDirectory = root.appendingPathComponent("Example App")
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleName": "Example App",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: appDirectory.appendingPathComponent("Info.plist"))
        configurationURL = root.appendingPathComponent(
            ConfigurationStore.defaultFileName
        )
        let integrated = try Integrator().integrate(
            projectRoot: root,
            configuration: fixtureConfiguration(),
            apply: true
        )
        try #require(integrated.applied)
    }

    func makeConfigurationLegacy(schemaVersion: Int) throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: configurationURL)
            ) as? [String: Any]
        )
        object["schemaVersion"] = schemaVersion
        object.removeValue(forKey: "tools")
        object.removeValue(forKey: "management")
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: configurationURL, options: .atomic)
    }

    func recordManifestHash(_ hash: String, for path: String) throws {
        let url = root.appendingPathComponent(
            ".sparklekit/manifest.json"
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        var managed = try #require(
            object["managedFiles"] as? [[String: Any]]
        )
        let index = try #require(
            managed.firstIndex {
                ($0["path"] as? String) == path
            }
        )
        managed[index]["sha256"] = hash
        object["managedFiles"] = managed
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url, options: .atomic)
    }

    func recordConfigurationHash(_ hash: String, for path: String) throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: configurationURL)
            ) as? [String: Any]
        )
        var management = try #require(
            object["management"] as? [String: Any]
        )
        var managed = try #require(
            management["managedFiles"] as? [[String: Any]]
        )
        let index = try #require(
            managed.firstIndex {
                ($0["path"] as? String) == path
            }
        )
        managed[index]["originalTemplateSHA256"] = hash
        management["managedFiles"] = managed
        object["management"] = management
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: configurationURL, options: .atomic)
    }

    func duplicateFirstManifestEntry() throws {
        let url = root.appendingPathComponent(
            ".sparklekit/manifest.json"
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        var managed = try #require(
            object["managedFiles"] as? [[String: Any]]
        )
        managed.append(try #require(managed.first))
        object["managedFiles"] = managed
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
