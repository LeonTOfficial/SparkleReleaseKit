#!/usr/bin/env swift

import CryptoKit
import Foundation

private struct UpdateManifest: Encodable {
    struct Asset: Encodable {
        var name: String
        var url: String
        var bytes: Int64
        var sha256: String
        var executablePath: String
        var resourceBundlePath: String
    }

    var schemaVersion: Int
    var version: String
    var channel: String
    var minimumMacOS: String
    var sourceCommit: String
    var releaseNotesURL: String
    var releaseNotes: [String]
    var asset: Asset
}

private enum ManifestToolError: LocalizedError {
    case usage(String)
    case invalid(String)
    case signingKey

    var errorDescription: String? {
        switch self {
        case .usage(let detail):
            "Usage error: \(detail)"
        case .invalid(let detail):
            "Invalid release metadata: \(detail)"
        case .signingKey:
            "SPARKLEKIT_UPDATE_SIGNING_PRIVATE_KEY is missing or invalid."
        }
    }
}

private struct Arguments {
    var values: [String: String] = [:]
    var notes: [String] = []

    init(_ raw: [String]) throws {
        let valueOptions: Set<String> = [
            "version", "asset", "asset-url", "source-commit",
            "release-notes-url", "output", "signature-output", "channel",
            "minimum-macos", "note",
        ]
        var index = 0
        while index < raw.count {
            let option = raw[index]
            guard option.hasPrefix("--") else {
                throw ManifestToolError.usage(
                    "unexpected argument \(option)"
                )
            }
            let name = String(option.dropFirst(2))
            guard valueOptions.contains(name), index + 1 < raw.count else {
                throw ManifestToolError.usage(
                    "missing value for \(option)"
                )
            }
            let value = raw[index + 1]
            guard !value.isEmpty, !value.hasPrefix("--") else {
                throw ManifestToolError.usage(
                    "missing value for \(option)"
                )
            }
            if name == "note" {
                notes.append(value)
            } else {
                guard values[name] == nil else {
                    throw ManifestToolError.usage(
                        "duplicate option \(option)"
                    )
                }
                values[name] = value
            }
            index += 2
        }
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name] else {
            throw ManifestToolError.usage("missing --\(name)")
        }
        return value
    }
}

private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_024 * 1_024),
        !data.isEmpty
    {
        hash.update(data: data)
    }
    return hash.finalize()
        .map { String(format: "%02x", $0) }
        .joined()
}

private func validateHTTPS(_ value: String, label: String) throws {
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
        throw ManifestToolError.invalid(
            "\(label) must be credential-free HTTPS without query or fragment"
        )
    }
}

private func isSemanticVersion(_ value: String) -> Bool {
    guard value.utf8.count <= 255,
        let expression = try? NSRegularExpression(
            pattern:
                #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        ),
        let match = expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ),
        match.range == NSRange(value.startIndex..., in: value)
    else {
        return false
    }
    guard match.range(at: 4).location != NSNotFound,
        let range = Range(match.range(at: 4), in: value)
    else {
        return true
    }
    return value[range].split(separator: ".").allSatisfy {
        Int($0) == nil || $0 == "0" || !$0.hasPrefix("0")
    }
}

private func run() throws {
    let arguments = try Arguments(
        Array(CommandLine.arguments.dropFirst())
    )
    let version = try arguments.required("version")
    guard isSemanticVersion(version) else {
        throw ManifestToolError.invalid("version is not semantic")
    }
    let channel = arguments.values["channel"] ?? "stable"
    guard ["stable", "beta"].contains(channel) else {
        throw ManifestToolError.invalid("channel must be stable or beta")
    }
    let minimumMacOS = arguments.values["minimum-macos"] ?? "13.0"
    guard
        minimumMacOS.range(
            of: #"^[0-9]+(?:\.[0-9]+){1,2}$"#,
            options: .regularExpression
        ) != nil
    else {
        throw ManifestToolError.invalid("minimum macOS version is invalid")
    }
    let commit = try arguments.required("source-commit")
    guard
        commit.range(
            of: #"^[0-9a-f]{40}$"#,
            options: .regularExpression
        ) != nil
    else {
        throw ManifestToolError.invalid(
            "source commit must be a full lowercase SHA"
        )
    }
    let assetURL = try arguments.required("asset-url")
    let notesURL = try arguments.required("release-notes-url")
    try validateHTTPS(assetURL, label: "asset URL")
    try validateHTTPS(notesURL, label: "release notes URL")
    guard !arguments.notes.isEmpty,
        arguments.notes.count <= 20,
        arguments.notes.allSatisfy({
            !$0.isEmpty
                && $0.utf8.count <= 1_024
                && !$0.unicodeScalars.contains(
                    where: CharacterSet.controlCharacters.contains
                )
        })
    else {
        throw ManifestToolError.invalid(
            "one to twenty bounded release notes are required"
        )
    }

    let asset = URL(
        fileURLWithPath: try arguments.required("asset")
    ).standardizedFileURL
    let values = try asset.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    let attributes = try FileManager.default.attributesOfItem(
        atPath: asset.path
    )
    let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        bytes > 0,
        bytes <= 256 * 1_024 * 1_024
    else {
        throw ManifestToolError.invalid(
            "asset must be a regular file between 1 byte and 256 MiB"
        )
    }

    let manifest = UpdateManifest(
        schemaVersion: 1,
        version: version,
        channel: channel,
        minimumMacOS: minimumMacOS,
        sourceCommit: commit,
        releaseNotesURL: notesURL,
        releaseNotes: arguments.notes,
        asset: .init(
            name: asset.lastPathComponent,
            url: assetURL,
            bytes: bytes,
            sha256: try sha256(asset),
            executablePath: "SparkleReleaseKit/sparklekit",
            resourceBundlePath:
                "SparkleReleaseKit/SparkleReleaseKit_SparkleReleaseKitCore.bundle"
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    let manifestData = try encoder.encode(manifest)

    guard
        let encodedKey = ProcessInfo.processInfo.environment[
            "SPARKLEKIT_UPDATE_SIGNING_PRIVATE_KEY"
        ], let keyData = Data(base64Encoded: encodedKey),
        keyData.count == 32,
        let privateKey = try? Curve25519.Signing.PrivateKey(
            rawRepresentation: keyData
        )
    else {
        throw ManifestToolError.signingKey
    }
    let signature = try privateKey.signature(for: manifestData)
        .base64EncodedString()
    let output = URL(
        fileURLWithPath: try arguments.required("output")
    ).standardizedFileURL
    let signatureOutput = URL(
        fileURLWithPath: try arguments.required("signature-output")
    ).standardizedFileURL
    guard output.path != signatureOutput.path else {
        throw ManifestToolError.invalid(
            "manifest and signature outputs must differ"
        )
    }
    try manifestData.write(to: output, options: .atomic)
    try Data((signature + "\n").utf8).write(
        to: signatureOutput,
        options: .atomic
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: output.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: signatureOutput.path
    )
    print("Created signed update manifest for \(version).")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(
        Data("Error: \(error.localizedDescription)\n".utf8)
    )
    exit(1)
}
