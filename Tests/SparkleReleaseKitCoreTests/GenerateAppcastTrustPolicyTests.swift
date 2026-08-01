import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("generate_appcast trust")
struct GenerateAppcastTrustPolicyTests {
    @Test("Accepts a valid signed regular executable")
    func acceptsLegitimateTool() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let decision = try evaluate(explicit: fixture.tool, root: fixture.root)

        #expect(decision.source == .explicitCLI)
        #expect(decision.signatureValid)
        #expect(decision.sha256.count == 64)
        #expect(decision.signingIdentifier != nil)
    }

    @Test("Rejects the wrong executable name")
    func rejectsWrongName() throws {
        let fixture = try signedToolFixture(name: "not-the-generator")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(explicit: fixture.tool, root: fixture.root)
        }
    }

    @Test("Rejects a tampered executable named generate_appcast")
    func rejectsTamperedTool() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handle = try FileHandle(forWritingTo: fixture.tool)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(explicit: fixture.tool, root: fixture.root)
        }
    }

    @Test("Rejects a non-executable file")
    func rejectsNonExecutable() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.tool.path
        )

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(explicit: fixture.tool, root: fixture.root)
        }
    }

    @Test("Rejects a directory in place of the tool")
    func rejectsDirectory() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("generate_appcast")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(explicit: directory, root: root)
        }
    }

    @Test("Rejects a symlink whose target or parent is unsafe")
    func rejectsUnsafeSymlinkTarget() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafe = root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: unsafe.path
        )
        let target = unsafe.appendingPathComponent("generate_appcast")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: target
        )
        let link = root.appendingPathComponent("generate_appcast")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(explicit: link, root: root)
        }
    }

    @Test("Rejects an unexpected signing identifier")
    func rejectsSigningIdentifier() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = GenerateAppcastTrustConfiguration(
            expectedSigningIdentifier: "invalid.example.identifier"
        )

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(
                explicit: fixture.tool,
                root: fixture.root,
                configuration: configuration
            )
        }
    }

    @Test("Rejects an unexpected Team ID")
    func rejectsTeamIdentifier() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = GenerateAppcastTrustConfiguration(
            expectedTeamIdentifier: "AAAAAAAAAA"
        )

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(
                explicit: fixture.tool,
                root: fixture.root,
                configuration: configuration
            )
        }
    }

    @Test("Rejects a SHA-256 value outside the allowlist")
    func rejectsHash() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = GenerateAppcastTrustConfiguration(
            allowedSHA256: [String(repeating: "0", count: 64)]
        )

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(
                explicit: fixture.tool,
                root: fixture.root,
                configuration: configuration
            )
        }
    }

    @Test("Accepts an exactly allowlisted SHA-256 value")
    func acceptsAllowedHash() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let digest = try FileDigest.sha256(of: fixture.tool)
        let configuration = GenerateAppcastTrustConfiguration(
            allowedSHA256: [digest]
        )

        let decision = try evaluate(
            explicit: fixture.tool,
            root: fixture.root,
            configuration: configuration
        )

        #expect(decision.sha256 == digest)
    }

    @Test("Rejects a helper writable by other users")
    func rejectsWorldWritableTool() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: fixture.tool.path
        )

        #expect(throws: GenerateAppcastTrustError.self) {
            try evaluate(explicit: fixture.tool, root: fixture.root)
        }
    }

    @Test("Rejects a CI environment override without opt-in")
    func rejectsCIEnvironmentOverride() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let environment = [
            "CI": "true",
            "SPARKLE_GENERATE_APPCAST": fixture.tool.path,
        ]

        #expect(throws: GenerateAppcastTrustError.self) {
            try GenerateAppcastTrustPolicy().evaluate(
                explicitURL: nil,
                projectRoot: fixture.root,
                configuration: .init(),
                allowProjectExecution: true,
                environment: environment
            )
        }
    }

    @Test("Explicit CLI paths take priority over the environment")
    func explicitPathWins() throws {
        let fixture = try signedToolFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let decision = try GenerateAppcastTrustPolicy().evaluate(
            explicitURL: fixture.tool,
            projectRoot: fixture.root,
            configuration: .init(),
            allowProjectExecution: true,
            environment: [
                "CI": "true",
                "SPARKLE_GENERATE_APPCAST": "/secret/untrusted/generate_appcast",
            ]
        )

        #expect(decision.source == .explicitCLI)
    }

    @Test("Trust failures do not echo environment secrets")
    func redactsEnvironmentSecrets() throws {
        let secret = "SYNTHETIC_SECRET_VALUE"
        let error: Error
        do {
            _ = try GenerateAppcastTrustPolicy().evaluate(
                explicitURL: nil,
                projectRoot: FileManager.default.temporaryDirectory,
                configuration: .init(),
                allowProjectExecution: false,
                environment: [
                    "CI": "true",
                    "SPARKLE_GENERATE_APPCAST":
                        "/tmp/\(secret)/generate_appcast",
                ]
            )
            Issue.record("Expected CI environment override rejection")
            return
        } catch let caught {
            error = caught
        }

        #expect(!error.localizedDescription.contains(secret))
    }

    private func evaluate(
        explicit: URL,
        root: URL,
        configuration: GenerateAppcastTrustConfiguration = .init()
    ) throws -> GenerateAppcastTrustDecision {
        try GenerateAppcastTrustPolicy().evaluate(
            explicitURL: explicit,
            projectRoot: root,
            configuration: configuration,
            allowProjectExecution: true,
            environment: [:]
        )
    }

    private func signedToolFixture(
        name: String = "generate_appcast"
    ) throws -> (root: URL, tool: URL) {
        let root = try privateTemporaryDirectory()
        let tool = root.appendingPathComponent(name)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: tool
        )
        return (root, tool)
    }

    private func privateTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleGenerateAppcastTrust-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        return root
    }
}
