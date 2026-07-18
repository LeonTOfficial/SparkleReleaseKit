import CryptoKit
import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("Sparkle signature verification")
struct UpdateSignatureVerifierTests {
    @Test("Cryptographically verifies the exact update archive")
    func verifiesArchive() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let diagnostic = try UpdateSignatureVerifier().verify(
            archiveURL: fixture.archive,
            appcast: fixture.appcast,
            publicEDKey: fixture.publicKey,
            expectedBuildVersion: "120"
        )

        #expect(diagnostic.severity == .pass)
    }

    @Test("Rejects an archive modified after signing")
    func rejectsTamperedArchive() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("signed-releasz".utf8).write(to: fixture.archive, options: .atomic)

        #expect(throws: UpdateSignatureVerificationError.self) {
            try UpdateSignatureVerifier().verify(
                archiveURL: fixture.archive,
                appcast: fixture.appcast,
                publicEDKey: fixture.publicKey,
                expectedBuildVersion: "120"
            )
        }
    }

    @Test("Rejects the wrong public key")
    func rejectsWrongKey() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrongKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

        #expect(throws: UpdateSignatureVerificationError.self) {
            try UpdateSignatureVerifier().verify(
                archiveURL: fixture.archive,
                appcast: fixture.appcast,
                publicEDKey: wrongKey,
                expectedBuildVersion: "120"
            )
        }
    }

    @Test("Rejects build-version and length mismatches")
    func rejectsMetadataMismatch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: UpdateSignatureVerificationError.self) {
            try UpdateSignatureVerifier().verify(
                archiveURL: fixture.archive,
                appcast: fixture.appcast,
                publicEDKey: fixture.publicKey,
                expectedBuildVersion: "121"
            )
        }

        var appcast = fixture.appcast
        appcast.enclosures[0].length += 1
        #expect(throws: UpdateSignatureVerificationError.self) {
            try UpdateSignatureVerifier().verify(
                archiveURL: fixture.archive,
                appcast: appcast,
                publicEDKey: fixture.publicKey,
                expectedBuildVersion: "120"
            )
        }
    }

    private func makeFixture() throws -> (
        root: URL,
        archive: URL,
        appcast: AppcastValidationResult,
        publicKey: String
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleSignature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("Example.1.2.0.zip")
        let data = Data("signed-release".utf8)
        try data.write(to: archive)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: data).base64EncodedString()
        let enclosure = AppcastEnclosure(
            url: "https://example.com/releases/Example.1.2.0.zip",
            version: "120",
            signature: signature,
            length: Int64(data.count)
        )
        let appcast = AppcastValidationResult(
            source: "fixture",
            itemCount: 1,
            versions: ["120"],
            enclosures: [enclosure],
            diagnostics: []
        )
        return (
            root,
            archive,
            appcast,
            key.publicKey.rawRepresentation.base64EncodedString()
        )
    }
}
