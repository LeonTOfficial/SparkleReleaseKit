import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("Configuration")
struct ConfigurationStoreTests {
    @Test("Round-trips a valid configuration")
    func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sparklekit.json")
        let expected = fixtureConfiguration()

        try ConfigurationStore().save(expected, to: url)
        let actual = try ConfigurationStore().load(from: url)

        #expect(actual == expected)
    }

    @Test("Rejects non-HTTPS feeds")
    func rejectsHTTP() {
        var configuration = fixtureConfiguration()
        configuration.updates.feedURL = "http://example.com/appcast.xml"

        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().validate(configuration)
        }
    }

    @Test("Rejects feed URLs containing query credentials or fragments")
    func rejectsDynamicFeedURLComponents() {
        var configuration = fixtureConfiguration()
        configuration.updates.feedURL = "https://example.com/appcast.xml?token=secret#latest"

        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().validate(configuration)
        }
    }

    @Test("Rejects symbolic-link configuration files")
    func rejectsSymlinkConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let actual = root.appendingPathComponent("actual.json")
        try ConfigurationStore().save(fixtureConfiguration(), to: actual)
        let link = root.appendingPathComponent("sparklekit.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)

        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().load(from: link)
        }
    }

    @Test("Rejects unknown secret-looking fields")
    func rejectsSecretField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sparklekit.json")
        try ConfigurationStore().save(fixtureConfiguration(), to: url)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["privateKey"] = "must-not-be-here"
        let data = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url)

        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().load(from: url)
        }
    }

    @Test("Rejects ambiguous project paths and unsafe branch names")
    func rejectsUnsafePathsAndBranches() {
        var configuration = fixtureConfiguration()
        configuration.project.container = "Projects//Example App.xcodeproj"
        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().validate(configuration)
        }

        configuration = fixtureConfiguration()
        configuration.github.pagesBranch = "release..candidate"
        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().validate(configuration)
        }
    }

    @Test("Rejects unsafe update channels")
    func rejectsUnsafeChannel() {
        var configuration = fixtureConfiguration()
        configuration.updates.channel = "beta --verbose"

        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().validate(configuration)
        }
    }

    @Test("Rejects GitHub expression injection in generated workflow values")
    func rejectsWorkflowExpressions() {
        var configuration = fixtureConfiguration()
        configuration.project.scheme = "Example ${{ github.token }}"

        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().validate(configuration)
        }
    }

    @Test("Migrates schema v1 notarization settings without requiring a paid certificate")
    func migratesLegacyConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sparklekit.json")
        let publicKey = Data(repeating: 7, count: 32).base64EncodedString()
        try """
        {
          "$schema": "\(SparkleKitConfiguration.schemaURL)",
          "schemaVersion": 1,
          "app": {"name":"Example App","bundleIdentifier":"com.example.app","minimumMacOS":"13.0","style":"swiftUI"},
          "project": {"container":"Example App.xcodeproj","scheme":"Example App","configuration":"Release","infoPlist":"Example App/Info.plist"},
          "github": {"owner":"example","repository":"example-app","pagesBranch":"gh-pages"},
          "updates": {"sparkleVersion":"2.9.4","feedURL":"https://example.com/appcast.xml","publicEDKey":"\(publicKey)","automaticChecks":true,"automaticDownloads":false},
          "distribution": {"installer":"dmg","updateArchive":"zip","notarization":"optional"}
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        let configuration = try ConfigurationStore().load(from: url)

        #expect(configuration.schemaVersion == 2)
        #expect(configuration.distribution.releaseMode == .free)
        #expect(!configuration.distribution.requireDeveloperID)
        #expect(!configuration.distribution.requireNotarization)
        #expect(configuration.distribution.requireSparkleSignature)
    }

    @Test("Keeps free and Developer ID distribution policies distinct")
    func validatesReleasePolicies() throws {
        let free = try ReleaseVerificationPolicy(
            distribution: .init(releaseMode: .free, expectedArchitectures: [.arm64])
        )
        #expect(free.requireSparkleSignature)
        #expect(!free.requireDeveloperID)
        #expect(!free.requireNotarization)
        #expect(free.allowAdHocSigning)

        let developerID = try ReleaseVerificationPolicy(
            distribution: .init(releaseMode: .developerID, expectedArchitectures: [.arm64])
        )
        #expect(developerID.requireDeveloperID)
        #expect(developerID.requireNotarization)
        #expect(!developerID.allowAdHocSigning)

        #expect(throws: ReleasePolicyError.self) {
            try ReleaseVerificationPolicy(
                distribution: .init(
                    releaseMode: .free,
                    requireDeveloperID: true,
                    expectedArchitectures: [.arm64]
                )
            )
        }
    }

    @Test("Rejects attempts to disable Sparkle update authentication")
    func rejectsDisabledSparkleSignature() throws {
        var configuration = fixtureConfiguration()
        configuration.distribution.requireSparkleSignature = false

        #expect(throws: ConfigurationError.self) {
            try ConfigurationStore().validate(configuration)
        }
    }
}

func fixtureConfiguration(publicKey: String = Data(repeating: 7, count: 32).base64EncodedString()) -> SparkleKitConfiguration {
    SparkleKitConfiguration(
        app: .init(name: "Example App", bundleIdentifier: "com.example.app", style: .swiftUI),
        project: .init(container: "Example App.xcodeproj", scheme: "Example App", infoPlist: "Example App/Info.plist"),
        github: .init(owner: "example", repository: "example-app"),
        updates: .init(feedURL: "https://example.github.io/example-app/appcast.xml", publicEDKey: publicKey)
    )
}
