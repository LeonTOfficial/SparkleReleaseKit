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
        guard let data = BoundedFileReader.data(at: fileURL, maximumBytes: Self.maximumBytes) else {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            throw AppcastValidationError.tooLarge(values?.fileSize ?? -1)
        }
        if containsEncodedASCII("<!DOCTYPE", in: data) {
            throw AppcastValidationError.malformed("Document type declarations are not allowed.")
        }

        let delegate = AppcastParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription ?? "Unknown XML parser error"
            throw AppcastValidationError.malformed(detail)
        }
        if let prohibitedMarkup = delegate.prohibitedMarkup {
            throw AppcastValidationError.malformed(prohibitedMarkup)
        }

        var diagnostics: [Diagnostic] = []
        let structureIsValid =
            delegate.rssCount == 1
            && delegate.channelCount == 1
            && delegate.structureErrors.isEmpty
        let structureDetail = delegate.structureErrors.isEmpty
            ? "The feed must contain exactly one unqualified rss root with one direct channel child."
            : delegate.structureErrors.joined(separator: " ")
        diagnostics.append(
            structureIsValid
                ? .init(.pass, "RSS structure", "The feed contains exactly one rss > channel hierarchy.")
                : .init(.failure, "RSS structure", structureDetail))

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
            let enclosureAttributesAreValid = enclosure.attributeErrors.isEmpty
            if !enclosureAttributesAreValid {
                diagnostics.append(
                    .init(
                        .failure,
                        "Item \(number) enclosure",
                        enclosure.attributeErrors.joined(separator: " ")
                    ))
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

            if enclosureAttributesAreValid,
                let url = enclosure.url,
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

    private func containsEncodedASCII(_ needle: String, in data: Data) -> Bool {
        let ascii = Array(needle.uppercased().utf8)
        let patterns: [[UInt8]] = [
            ascii,
            ascii.flatMap { [$0, 0] },
            ascii.flatMap { [0, $0] },
            ascii.flatMap { [$0, 0, 0, 0] },
            ascii.flatMap { [0, 0, 0, $0] },
        ]
        let normalized = Data(data.map { value in
            value >= 97 && value <= 122 ? value - 32 : value
        })
        return patterns.contains { normalized.range(of: Data($0)) != nil }
    }
}

private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    private static let sparkleNamespaceURI = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    struct Enclosure {
        var url: String?
        var version: String?
        var signature: String?
        var length: String?
        var attributeErrors: [String] = []
    }

    struct Item {
        var enclosure: Enclosure?
        var enclosureCount = 0
    }

    private struct Element {
        var localName: String
        var namespaceURI: String?
        var qualifiedName: String

        var isUnqualified: Bool {
            namespaceURI == nil && !qualifiedName.contains(":")
        }
    }

    private struct Attribute {
        var localName: String
        var namespaceURI: String?
        var prefix: String?
        var qualifiedName: String
        var value: String
    }

    var rssCount = 0
    var channelCount = 0
    var structureErrors: [String] = []
    var prohibitedMarkup: String?
    var items: [Item] = []
    private var elementStack: [Element] = []
    private var currentItem: Item?
    private var currentItemDepth: Int?
    private var namespaceMappings: [String: [String]] = [:]

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaceMappings[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        namespaceMappings[prefix]?.removeLast()
        if namespaceMappings[prefix]?.isEmpty == true {
            namespaceMappings[prefix] = nil
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = Element(
            localName: elementName,
            namespaceURI: normalized(namespaceURI),
            qualifiedName: qName ?? elementName
        )
        let parent = elementStack.last
        let depth = elementStack.count

        switch elementName {
        case "rss":
            rssCount += 1
            if depth != 0 || !element.isUnqualified {
                recordStructureError("rss must be the unqualified document root.")
            }
        case "channel":
            channelCount += 1
            if depth != 1 || parent?.localName != "rss" || parent?.isUnqualified != true || !element.isUnqualified {
                recordStructureError("channel must be the single unqualified direct child of rss.")
            }
            if channelCount > 1 {
                recordStructureError("The feed must not contain multiple channel elements.")
            }
        case "item":
            if depth == 2,
                parent?.localName == "channel",
                parent?.isUnqualified == true,
                element.isUnqualified,
                currentItem == nil
            {
                currentItem = Item()
                currentItemDepth = depth
            } else {
                recordStructureError("item must be an unqualified direct child of channel.")
            }
        case "enclosure":
            if depth == 3,
                parent?.localName == "item",
                parent?.isUnqualified == true,
                element.isUnqualified,
                currentItemDepth == depth - 1,
                currentItem != nil
            {
                currentItem?.enclosureCount += 1
                if currentItem?.enclosure == nil {
                    currentItem?.enclosure = parseEnclosureAttributes(attributeDict)
                }
            } else {
                recordStructureError("enclosure must be an unqualified direct child of item.")
            }
        default:
            break
        }

        elementStack.append(element)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let depth = elementStack.count - 1
        if elementName == "item", currentItemDepth == depth, let currentItem {
            items.append(currentItem)
            self.currentItem = nil
            currentItemDepth = nil
        }
        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        prohibitedMarkup = "Document type and entity declarations are not allowed."
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        prohibitedMarkup = "Document type and entity declarations are not allowed."
    }

    private func parseEnclosureAttributes(_ attributeDict: [String: String]) -> Enclosure {
        let attributes = attributeDict.map { qualifiedName, value in
            resolveAttribute(qualifiedName: qualifiedName, value: value)
        }.sorted { $0.qualifiedName < $1.qualifiedName }

        let url = validatedAttribute(named: "url", namespaceURI: nil, in: attributes)
        let length = validatedAttribute(named: "length", namespaceURI: nil, in: attributes)
        let version = validatedAttribute(named: "version", namespaceURI: Self.sparkleNamespaceURI, in: attributes)
        let signature = validatedAttribute(named: "edSignature", namespaceURI: Self.sparkleNamespaceURI, in: attributes)

        return Enclosure(
            url: url.value,
            version: version.value,
            signature: signature.value,
            length: length.value,
            attributeErrors: url.errors + length.errors + version.errors + signature.errors
        )
    }

    private func validatedAttribute(
        named localName: String,
        namespaceURI: String?,
        in attributes: [Attribute]
    ) -> (value: String?, errors: [String]) {
        let candidates = attributes.filter { $0.localName == localName }
        guard !candidates.isEmpty else { return (nil, []) }

        let expected = candidates.filter { attribute in
            if let namespaceURI {
                return attribute.namespaceURI == namespaceURI && attribute.prefix != nil
            }
            return attribute.namespaceURI == nil && attribute.prefix == nil
        }

        if candidates.count != 1 || expected.count != 1 {
            let requirement = namespaceURI == nil
                ? "must be unqualified"
                : "must use the official Sparkle namespace URI"
            return (
                nil,
                ["The enclosure attribute \(localName) \(requirement) and must not be duplicated or shadowed."]
            )
        }
        return (expected[0].value, [])
    }

    private func resolveAttribute(qualifiedName: String, value: String) -> Attribute {
        let parts = qualifiedName.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let prefix = String(parts[0])
            return Attribute(
                localName: String(parts[1]),
                namespaceURI: namespaceMappings[prefix]?.last,
                prefix: prefix,
                qualifiedName: qualifiedName,
                value: value
            )
        }
        return Attribute(
            localName: qualifiedName,
            namespaceURI: nil,
            prefix: nil,
            qualifiedName: qualifiedName,
            value: value
        )
    }

    private func normalized(_ namespaceURI: String?) -> String? {
        guard let namespaceURI, !namespaceURI.isEmpty else { return nil }
        return namespaceURI
    }

    private func recordStructureError(_ detail: String) {
        if !structureErrors.contains(detail) {
            structureErrors.append(detail)
        }
    }
}
