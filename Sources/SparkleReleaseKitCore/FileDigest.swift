import CryptoKit
import Foundation

enum FileDigest {
    private static let chunkBytes = 1_024 * 1_024

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hash = SHA256()
        while let data = try handle.read(upToCount: chunkBytes), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
