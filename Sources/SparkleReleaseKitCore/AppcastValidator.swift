import Foundation

public enum AppcastValidationError: LocalizedError {
    case missing(URL)
    case tooLarge(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let url):
            "The appcast does not exist at \(url.path)."
        case .tooLarge(let bytes):
            "The appcast is unexpectedly large (\(bytes) bytes)."
        case .malformed(let detail):
            "The appcast XML is malformed: \(detail)"
        }
    }
}

public struct AppcastValidator: Sendable {
    private static let maximumBytes = 10 * 1_024 * 1_024

    public init() {}

    public func validate(fileURL: URL) throws -> AppcastValidationResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AppcastValidationError.missing(fileURL)
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
            let size = values.fileSize,
            size <= Self.maximumBytes
        else {
            throw AppcastValidationError.tooLarge(values.fileSize ?? -1)
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        if let text = String(data: data, encoding: .utf8),
            text.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil
        {
            throw AppcastValidationError.malformed("Document type declarations are not allowed.")
        }

        let delegate = AppcastParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription ?? "Unknown XML parser error"
            throw AppcastValidationError.malformed(detail)
        }

        var diagnostics: [Diagnostic] = []
        diagnostics.append(
            delegate.sawRSS && delegate.sawChannel
                ? .init(.pass, "RSS structure", "The feed contains an RSS channel.")
                : .init(.failure, "RSS structure", "The feed must contain rss and channel elements."))

        if delegate.items.isEmpty {
            diagnostics.append(.init(.failure, "Update items", "The feed does not contain an update item."))
        } else {
            diagnostics.append(.init(.pass, "Update items", "Found \(delegate.items.count) update item(s)."))
        }

        var versions: [String] = []
        var enclosures: [AppcastEnclosure] = []
        for (index, item) in delegate.items.enumerated() {
            let number = index + 1
            guard item.enclosureCount == 1 else {
                diagnostics.append(
                    .init(
                        .failure,
                        "Item \(number) enclosure",
                        "Each update item must contain exactly one enclosure; found \(item.enclosureCount)."
                    ))
                continue
            }
            guard let enclosure = item.enclosure else {
                diagnostics.append(.init(.failure, "Item \(number) enclosure", "The update item has no enclosure element."))
                continue
            }

            if let urlString = enclosure.url,
                let url = URL(string: urlString),
                url.scheme?.lowercased() == "https",
                url.host != nil,
                url.user == nil,
                url.password == nil,
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == nil,
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment == nil
            {
                diagnostics.append(.init(.pass, "Item \(number) download URL", urlString))
            } else {
                diagnostics.append(
                    .init(
                        .failure,
                        "Item \(number) download URL",
                        "Every update archive must use an absolute, credential-free HTTPS URL without a query or fragment."
                    ))
            }

            if let version = enclosure.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                versions.append(version)
            } else {
                diagnostics.append(.init(.failure, "Item \(number) version", "sparkle:version is missing."))
            }

            if let signature = enclosure.signature,
                let decodedSignature = Data(base64Encoded: signature),
                decodedSignature.count == 64
            {
                diagnostics.append(.init(.pass, "Item \(number) EdDSA signature", "A 64-byte base64 Ed25519 signature is present."))
            } else {
                diagnostics.append(
                    .init(
                        .failure,
                        "Item \(number) EdDSA signature",
                        "sparkle:edSignature must be a 64-byte base64 Ed25519 signature."
                    ))
            }

            if let length = enclosure.length.flatMap(Int64.init), length > 0 {
                diagnostics.append(.init(.pass, "Item \(number) length", "The enclosure declares \(length) bytes."))
            } else {
                diagnostics.append(.init(.failure, "Item \(number) length", "The enclosure length must be a positive integer."))
            }

            if let url = enclosure.url,
                let version = enclosure.version?.trimmingCharacters(in: .whitespacesAndNewlines),
                !version.isEmpty,
                let signature = enclosure.signature,
                let length = enclosure.length.flatMap(Int64.init),
                length > 0
            {
                enclosures.append(.init(url: url, version: version, signature: signature, length: length))
            }
        }

        let duplicates = Dictionary(grouping: versions, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        diagnostics.append(
            duplicates.isEmpty
                ? .init(.pass, "Version uniqueness", "Each update item has a unique build version.")
                : .init(.failure, "Version uniqueness", "Duplicate sparkle:version values: \(duplicates.joined(separator: ", "))."))

        return AppcastValidationResult(
            source: fileURL.standardizedFileURL.path,
            itemCount: delegate.items.count,
            versions: versions,
            enclosures: enclosures,
            diagnostics: diagnostics
        )
    }
}

private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    struct Enclosure {
        var url: String?
        var version: String?
        var signature: String?
        var length: String?
    }

    struct Item {
        var enclosure: Enclosure?
        var enclosureCount = 0
    }

    var sawRSS = false
    var sawChannel = false
    var items: [Item] = []
    private var currentItem: Item?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "rss":
            sawRSS = true
        case "channel":
            sawChannel = true
        case "item":
            currentItem = Item()
        case "enclosure":
            guard currentItem != nil else { return }
            currentItem?.enclosureCount += 1
            if currentItem?.enclosure == nil {
                currentItem?.enclosure = Enclosure(
                    url: attributeDict["url"],
                    version: attributeDict["sparkle:version"] ?? attributeDict["version"],
                    signature: attributeDict["sparkle:edSignature"] ?? attributeDict["edSignature"],
                    length: attributeDict["length"]
                )
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == "item", let currentItem else { return }
        items.append(currentItem)
        self.currentItem = nil
    }
}
