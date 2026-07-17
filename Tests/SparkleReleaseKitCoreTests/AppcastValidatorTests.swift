import Foundation
import Testing
@testable import SparkleReleaseKitCore

@Suite("Appcast validation")
struct AppcastValidatorTests {
    @Test("Accepts a structurally signed HTTPS appcast")
    func acceptsValidFeed() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeFeed(enclosure: """
        <enclosure url="https://github.com/example/app/releases/download/v1.2.0/App.zip"
          sparkle:version="120" length="42" type="application/octet-stream"
          sparkle:edSignature="\(signature)" />
        """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.itemCount == 1)
        #expect(result.versions == ["120"])
        #expect(!result.diagnostics.contains { $0.severity == .failure })
    }

    @Test("Rejects credentials in download URLs and short signatures")
    func rejectsCredentialsAndShortSignature() throws {
        let feed = try writeFeed(enclosure: """
        <enclosure url="https://user:password@example.com/App.zip"
          sparkle:version="120" length="42" sparkle:edSignature="QUFBQQ==" />
        """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.filter { $0.severity == .failure }.count >= 2)
    }

    @Test("Rejects query-bearing archive URLs")
    func rejectsArchiveURLQuery() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let url = try writeFeed(enclosure: """
        <enclosure url="https://example.com/App.zip?token=secret&amp;channel=stable"
          sparkle:version="1" length="100" sparkle:edSignature="\(signature)" />
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: url)

        #expect(result.diagnostics.contains { $0.severity == .failure && $0.title.contains("download URL") })
    }

    @Test("Rejects HTTP downloads and missing signatures")
    func rejectsUnsafeFeed() throws {
        let feed = try writeFeed(enclosure: """
        <enclosure url="http://example.com/App.zip" sparkle:version="120" length="42" />
        """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.filter { $0.severity == .failure }.count >= 2)
    }

    @Test("Rejects external entity expansion")
    func rejectsExternalEntityUse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SparkleFeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let feed = root.appendingPathComponent("appcast.xml")
        try """
        <?xml version="1.0"?>
        <!DOCTYPE rss [<!ENTITY external SYSTEM "file:///etc/passwd">]>
        <rss version="2.0"><channel><title>&external;</title></channel></rss>
        """.write(to: feed, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AppcastValidationError.self) {
            try AppcastValidator().validate(fileURL: feed)
        }
    }

    @Test("Rejects ambiguous items with multiple enclosures")
    func rejectsMultipleEnclosures() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeFeed(enclosure: """
        <enclosure url="https://example.com/One.zip" sparkle:version="120" length="42" sparkle:edSignature="\(signature)" />
        <enclosure url="https://example.com/Two.zip" sparkle:version="121" length="43" sparkle:edSignature="\(signature)" />
        """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure && $0.title.contains("enclosure") })
    }

    private func writeFeed(enclosure: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SparkleFeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let feed = root.appendingPathComponent("appcast.xml")
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Example App updates</title>
            <item>
              <title>Version 1.2.0</title>
              \(enclosure)
            </item>
          </channel>
        </rss>
        """.write(to: feed, atomically: true, encoding: .utf8)
        return feed
    }
}
