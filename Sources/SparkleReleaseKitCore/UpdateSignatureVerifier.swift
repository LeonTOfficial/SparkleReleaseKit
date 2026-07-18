import CryptoKit
import Foundation

public enum UpdateSignatureVerificationError: LocalizedError, Equatable {
    case invalidPublicKey
    case archiveMissing(URL)
    case archiveTooLarge(Int64)
    case noMatchingEnclosure(String)
    case ambiguousEnclosure(String)
    case versionMismatch(expected: String, found: String)
    case lengthMismatch(expected: Int64, found: Int64)
    case invalidSignatureEncoding
    case invalidSignature

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            "The Sparkle public key must be a 32-byte base64 Ed25519 key."
        case .archiveMissing(let url):
            "The update archive does not exist at \(url.path)."
        case .archiveTooLarge(let bytes):
            "The update archive is too large for safe signature verification (\(bytes) bytes)."
        case .noMatchingEnclosure(let name):
            "The appcast has no enclosure for \(name)."
        case .ambiguousEnclosure(let name):
            "The appcast contains more than one enclosure for \(name)."
        case .versionMismatch(let expected, let found):
            "The appcast build version is \(found), but the archive contains \(expected)."
        case .lengthMismatch(let expected, let found):
            "The appcast declares \(found) bytes, but the archive contains \(expected) bytes."
        case .invalidSignatureEncoding:
            "The appcast EdDSA signature is not a 64-byte base64 Ed25519 signature."
        case .invalidSignature:
            "The Sparkle EdDSA signature does not authenticate this archive."
        }
    }
}

public struct UpdateSignatureVerifier: Sendable {
    private static let maximumArchiveBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    public init() {}

    public func verify(
        archiveURL: URL,
        appcast: AppcastValidationResult,
        publicEDKey: String,
        expectedBuildVersion: String
    ) throws -> Diagnostic {
        guard let keyData = Data(base64Encoded: publicEDKey), keyData.count == 32,
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            throw UpdateSignatureVerificationError.invalidPublicKey
        }

        let archive = archiveURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw UpdateSignatureVerificationError.archiveMissing(archive)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        let archiveBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard archiveBytes >= 0, archiveBytes <= Self.maximumArchiveBytes else {
            throw UpdateSignatureVerificationError.archiveTooLarge(archiveBytes)
        }

        let matches = appcast.enclosures.filter {
            URL(string: $0.url)?.lastPathComponent == archive.lastPathComponent
        }
        guard !matches.isEmpty else {
            throw UpdateSignatureVerificationError.noMatchingEnclosure(archive.lastPathComponent)
        }
        guard matches.count == 1, let enclosure = matches.first else {
            throw UpdateSignatureVerificationError.ambiguousEnclosure(archive.lastPathComponent)
        }
        guard enclosure.version == expectedBuildVersion else {
            throw UpdateSignatureVerificationError.versionMismatch(
                expected: expectedBuildVersion,
                found: enclosure.version
            )
        }
        guard enclosure.length == archiveBytes else {
            throw UpdateSignatureVerificationError.lengthMismatch(expected: archiveBytes, found: enclosure.length)
        }
        guard let signature = Data(base64Encoded: enclosure.signature), signature.count == 64 else {
            throw UpdateSignatureVerificationError.invalidSignatureEncoding
        }

        let archiveData = try Data(contentsOf: archive, options: [.mappedIfSafe, .uncached])
        guard publicKey.isValidSignature(signature, for: archiveData) else {
            throw UpdateSignatureVerificationError.invalidSignature
        }
        return .init(
            .pass,
            "Sparkle EdDSA signature",
            "The appcast signature cryptographically authenticates \(archive.lastPathComponent)."
        )
    }
}
