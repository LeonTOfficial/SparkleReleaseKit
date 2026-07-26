import Foundation
import Testing

@testable import SparkleReleaseKitCore

@Suite("Diagnostic contracts")
struct DiagnosticsTests {
    @Test("Catalog identifiers are stable and self-consistent")
    func catalogIdentifiersAreStable() {
        let documentationRoot =
            "https://github.com/LeonTOfficial/SparkleReleaseKit/blob/main/"
        let repository = repositoryRoot()
        #expect(DiagnosticCatalog.definitions.count >= 9)
        for (identifier, definition) in DiagnosticCatalog.definitions {
            #expect(identifier == definition.id)
            #expect(identifier.range(of: #"^SRK[0-9]{4}$"#, options: .regularExpression) != nil)
            #expect(definition.documentationURL.hasPrefix(documentationRoot))
            let relativePath = String(
                definition.documentationURL.dropFirst(documentationRoot.count)
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: repository.appendingPathComponent(relativePath).path
                )
            )
        }
        #expect(DiagnosticCatalog.identifier(for: "Code signature") == "SRK2101")
        #expect(DiagnosticCatalog.identifier(for: "Nested signature Sparkle.framework") == "SRK2103")
    }

    @Test("Terminal rendering neutralizes control and bidi characters")
    func terminalOutputIsSanitized() {
        let raw = "safe\u{001B}[31m\u{202E}right-to-left\nnext"

        let sanitized = TerminalSanitizer.text(raw)

        #expect(!sanitized.contains("\u{001B}"))
        #expect(!sanitized.contains("\u{202E}"))
        #expect(sanitized.contains("\\u{1B}"))
        #expect(sanitized.contains("\\u{202E}"))
        #expect(sanitized.contains("\nnext"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
