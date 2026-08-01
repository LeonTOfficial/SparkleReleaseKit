import CryptoKit
import Foundation

public enum SelfUpdateTrustRoot {
    // The matching private key is stored only as a protected release secret.
    public static let publicKeyBase64 =
        "I6NIWwnQ5Nm+KMdT1OXNDW1YGmNOE9K1NZuKcCx+7Ro="
}

public struct SelfUpdateManifestVerifier: Sendable {
    private static let maximumManifestBytes = 1_024 * 1_024
    private static let maximumAssetBytes: Int64 = 256 * 1_024 * 1_024
    private let publicKeyBase64: String

    public init(
        publicKeyBase64: String = SelfUpdateTrustRoot.publicKeyBase64
    ) {
        self.publicKeyBase64 = publicKeyBase64
    }

    public func verify(
        manifestURL: URL,
        signatureURL: URL,
        expectedChannel: SelfUpdateChannel = .stable
    ) throws -> SelfUpdateManifest {
        guard
            let manifest = BoundedFileReader.data(
                at: manifestURL,
                maximumBytes: Self.maximumManifestBytes
            ),
            let signature = BoundedFileReader.data(
                at: signatureURL,
                maximumBytes: 4 * 1_024
            )
        else {
            throw SelfUpdateError.malformedManifest(
                "manifest or signature file is unsafe"
            )
        }
        return try verify(
            manifestData: manifest,
            signatureData: signature,
            expectedChannel: expectedChannel
        )
    }

    public func verify(
        manifestData: Data,
        signatureData: Data,
        expectedChannel: SelfUpdateChannel = .stable
    ) throws -> SelfUpdateManifest {
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw SelfUpdateError.responseTooLarge
        }
        guard let keyData = Data(base64Encoded: publicKeyBase64),
            keyData.count == 32,
            let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: keyData
            )
        else {
            throw SelfUpdateError.invalidTrustRoot
        }
        guard
            let signatureText = String(data: signatureData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let signature = Data(base64Encoded: signatureText),
            signature.count == 64,
            publicKey.isValidSignature(signature, for: manifestData)
        else {
            throw SelfUpdateError.invalidManifestSignature
        }
        try validateRawDocument(manifestData)
        let manifest: SelfUpdateManifest
        do {
            manifest = try JSONDecoder().decode(
                SelfUpdateManifest.self,
                from: manifestData
            )
        } catch {
            throw SelfUpdateError.malformedManifest("JSON decoding failed")
        }
        try validate(manifest, expectedChannel: expectedChannel)
        return manifest
    }

    private func validate(
        _ manifest: SelfUpdateManifest,
        expectedChannel: SelfUpdateChannel
    ) throws {
        guard manifest.schemaVersion == 1 else {
            throw SelfUpdateError.unsupportedManifest
        }
        guard SemanticVersion(manifest.version) != nil else {
            throw SelfUpdateError.malformedManifest("version is not semantic")
        }
        guard manifest.channel == expectedChannel else {
            throw SelfUpdateError.malformedManifest("channel does not match")
        }
        guard
            manifest.minimumMacOS.range(
                of: #"^[0-9]+(?:\.[0-9]+){1,2}$"#,
                options: .regularExpression
            ) != nil
        else {
            throw SelfUpdateError.malformedManifest(
                "minimumMacOS is invalid"
            )
        }
        guard
            manifest.sourceCommit.range(
                of: #"^[0-9a-f]{40}$"#,
                options: .regularExpression
            ) != nil
        else {
            throw SelfUpdateError.malformedManifest(
                "sourceCommit must be a full commit SHA"
            )
        }
        try validateHTTPS(manifest.releaseNotesURL)
        try validateHTTPS(manifest.asset.url)
        guard manifest.releaseNotes.count <= 20,
            manifest.releaseNotes.allSatisfy({
                !$0.isEmpty
                    && $0.utf8.count <= 1_024
                    && !$0.unicodeScalars.contains(
                        where: CharacterSet.controlCharacters.contains
                    )
            })
        else {
            throw SelfUpdateError.malformedManifest(
                "releaseNotes exceed their limits"
            )
        }
        guard
            manifest.asset.name
                == URL(fileURLWithPath: manifest.asset.name).lastPathComponent,
            manifest.asset.name.hasSuffix(".zip"),
            manifest.asset.bytes > 0,
            manifest.asset.bytes <= Self.maximumAssetBytes,
            manifest.asset.sha256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil,
            safeRelativePath(manifest.asset.executablePath),
            safeRelativePath(manifest.asset.resourceBundlePath)
        else {
            throw SelfUpdateError.malformedManifest(
                "asset metadata is unsafe"
            )
        }
    }

    private func validateHTTPS(_ value: String) throws {
        guard let url = URL(string: value),
            url.scheme?.lowercased() == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil,
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.query == nil,
            components.fragment == nil
        else {
            throw SelfUpdateError.unsafeURL
        }
    }

    private func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= 4_096,
            !value.hasPrefix("/"),
            !value.contains("\\"),
            !value.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
            )
        else {
            return false
        }
        return !value.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).contains {
            $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.count > 255
        }
    }

    private func validateRawDocument(_ data: Data) throws {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw SelfUpdateError.malformedManifest(
                "root must be an object"
            )
        }
        let rootKeys: Set<String> = [
            "schemaVersion", "version", "channel", "minimumMacOS",
            "sourceCommit", "releaseNotesURL", "releaseNotes", "asset",
        ]
        guard Set(root.keys).subtracting(rootKeys).isEmpty,
            let asset = root["asset"] as? [String: Any]
        else {
            throw SelfUpdateError.malformedManifest(
                "unknown or missing root fields"
            )
        }
        let assetKeys: Set<String> = [
            "name", "url", "bytes", "sha256", "executablePath",
            "resourceBundlePath",
        ]
        guard Set(asset.keys).subtracting(assetKeys).isEmpty else {
            throw SelfUpdateError.malformedManifest(
                "unknown asset fields"
            )
        }
    }
}
