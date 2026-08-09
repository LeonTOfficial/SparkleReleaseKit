import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("Appcast validation")
struct AppcastValidatorTests {
    @Test("Accepts a structurally signed HTTPS appcast")
    func acceptsValidFeed() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeFeed(
            enclosure: """
                <enclosure url="https://github.com/example/app/releases/download/v1.2.0/App.zip"
                  sparkle:version="120" length="42" type="application/octet-stream"
                  sparkle:edSignature="\(signature)" />
                """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.itemCount == 1)
        #expect(result.versions == ["120"])
        #expect(result.enclosures.count == 1)
        #expect(result.enclosures.first?.length == 42)
        #expect(!result.diagnostics.contains { $0.severity == .failure })
    }

    @Test("Accepts the official Sparkle namespace with an alternative prefix")
    func acceptsOfficialNamespaceWithAlternativePrefix() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeDocument(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:update="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <title>Example App updates</title>
                <item>
                  <title>Version 1.2.0</title>
                  <enclosure url="https://example.com/App.zip"
                    update:version="120" length="42" type="application/octet-stream"
                    update:edSignature="\(signature)" />
                </item>
              </channel>
            </rss>
            """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.versions == ["120"])
        #expect(result.enclosures.count == 1)
        #expect(!result.diagnostics.contains { $0.severity == .failure })
    }

    @Test("Rejects an item outside channel and unqualified Sparkle attributes")
    func rejectsItemOutsideChannelAndUnqualifiedSparkleAttributes() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeDocument(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><title>Example App updates</title></channel>
              <item>
                <enclosure url="https://example.com/App.zip"
                  version="120" length="42" edSignature="\(signature)" />
              </item>
            </rss>
            """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure })
        #expect(result.enclosures.isEmpty)
    }

    @Test("Rejects Sparkle attributes bound to the wrong namespace URI")
    func rejectsWrongSparkleNamespaceURI() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeDocument(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="https://example.invalid/not-sparkle">
              <channel>
                <item>
                  <enclosure url="https://example.com/App.zip"
                    sparkle:version="120" length="42" sparkle:edSignature="\(signature)" />
                </item>
              </channel>
            </rss>
            """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure })
        #expect(result.enclosures.isEmpty)
    }

    @Test("Rejects unqualified Sparkle attributes inside a valid hierarchy")
    func rejectsMissingSparkleNamespace() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeDocument(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <item>
                  <enclosure url="https://example.com/App.zip"
                    version="120" length="42" edSignature="\(signature)" />
                </item>
              </channel>
            </rss>
            """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure })
        #expect(result.enclosures.isEmpty)
    }

    @Test("Rejects shadowed Sparkle attributes")
    func rejectsShadowedSparkleAttributes() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeDocument(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0"
              xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
              xmlns:other="https://example.invalid/not-sparkle">
              <channel>
                <item>
                  <enclosure url="https://example.com/App.zip"
                    sparkle:version="120" version="999" length="42"
                    sparkle:edSignature="\(signature)" other:edSignature="\(signature)" />
                </item>
              </channel>
            </rss>
            """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure })
        #expect(result.enclosures.isEmpty)
    }

    @Test("Rejects duplicate expanded Sparkle attributes")
    func rejectsDuplicateExpandedSparkleAttributes() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeDocument(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0"
              xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
              xmlns:update="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <enclosure url="https://example.com/App.zip"
                    sparkle:version="120" update:version="121" length="42"
                    sparkle:edSignature="\(signature)" />
                </item>
              </channel>
            </rss>
            """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure })
        #expect(result.enclosures.isEmpty)
    }

    @Test("Rejects multiple RSS channels")
    func rejectsMultipleChannels() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeDocument(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item><enclosure url="https://example.com/One.zip"
                  sparkle:version="120" length="42" sparkle:edSignature="\(signature)" /></item>
              </channel>
              <channel>
                <item><enclosure url="https://example.com/Two.zip"
                  sparkle:version="121" length="43" sparkle:edSignature="\(signature)" /></item>
              </channel>
            </rss>
            """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure && $0.title == "RSS structure" })
    }

    @Test("Rejects an enclosure that is not a direct item child")
    func rejectsNestedEnclosure() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeDocument(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <payload>
                    <enclosure url="https://example.com/App.zip"
                      sparkle:version="120" length="42" sparkle:edSignature="\(signature)" />
                  </payload>
                </item>
              </channel>
            </rss>
            """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure })
        #expect(result.enclosures.isEmpty)
    }

    @Test("Rejects credentials in download URLs and short signatures")
    func rejectsCredentialsAndShortSignature() throws {
        let feed = try writeFeed(
            enclosure: """
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
        let url = try writeFeed(
            enclosure: """
                <enclosure url="https://example.com/App.zip?token=secret&amp;channel=stable"
                  sparkle:version="1" length="100" sparkle:edSignature="\(signature)" />
                """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: url)

        #expect(result.diagnostics.contains { $0.severity == .failure && $0.title.contains("download URL") })
    }

    @Test("Rejects HTTP downloads and missing signatures")
    func rejectsUnsafeFeed() throws {
        let feed = try writeFeed(
            enclosure: """
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

    @Test("Rejects a UTF-16 document type declaration")
    func rejectsUTF16Doctype() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SparkleFeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let feed = root.appendingPathComponent("appcast.xml")
        let xml = """
        <?xml version="1.0" encoding="UTF-16"?>
        <!DOCTYPE rss [<!ENTITY external SYSTEM "file:///etc/passwd">]>
        <rss version="2.0"><channel><title>&external;</title></channel></rss>
        """
        try #require(xml.data(using: .utf16LittleEndian)).write(to: feed)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AppcastValidationError.self) {
            try AppcastValidator().validate(fileURL: feed)
        }
    }

    @Test("Rejects ambiguous items with multiple enclosures")
    func rejectsMultipleEnclosures() throws {
        let signature = Data(repeating: 0x41, count: 64).base64EncodedString()
        let feed = try writeFeed(
            enclosure: """
                <enclosure url="https://example.com/One.zip" sparkle:version="120" length="42" sparkle:edSignature="\(signature)" />
                <enclosure url="https://example.com/Two.zip" sparkle:version="121" length="43" sparkle:edSignature="\(signature)" />
                """)
        defer { try? FileManager.default.removeItem(at: feed.deletingLastPathComponent()) }

        let result = try AppcastValidator().validate(fileURL: feed)

        #expect(result.diagnostics.contains { $0.severity == .failure && $0.title.contains("enclosure") })
    }

    private func writeFeed(enclosure: String) throws -> URL {
        try writeDocument(
            """
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
            """)
    }

    private func writeDocument(_ xml: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SparkleFeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let feed = root.appendingPathComponent("appcast.xml")
        try xml.write(to: feed, atomically: true, encoding: .utf8)
        return feed
    }
}
