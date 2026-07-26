import Foundation

public enum TemplateError: LocalizedError {
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name): "The bundled template \(name) is missing."
        }
    }
}

struct TemplateRenderer {
    let configuration: SparkleKitConfiguration

    func render(named name: String) throws -> Data {
        guard let resourceRoot = Bundle.module.resourceURL else {
            throw TemplateError.missing(name)
        }
        let candidates = [
            resourceRoot.appendingPathComponent("Templates/\(name)"),
            resourceRoot.appendingPathComponent("Resources/Templates/\(name)"),
        ]
        guard let data = candidates.compactMap({ try? Data(contentsOf: $0) }).first,
              let text = String(data: data, encoding: .utf8) else {
            throw TemplateError.missing(name)
        }
        guard let expression = try? NSRegularExpression(pattern: #"\{\{([A-Z0-9_]+)\}\}"#) else {
            throw TemplateError.missing(name)
        }
        var rendered = text
        let values = replacements(markdown: name.hasSuffix(".md.template"))
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: rendered),
                  let nameRange = Range(match.range(at: 1), in: rendered),
                  let value = values[String(rendered[nameRange])] else { continue }
            rendered.replaceSubrange(wholeRange, with: value)
        }
        return Data(rendered.utf8)
    }

    private func replacements(markdown: Bool) -> [String: String] {
        let raw = [
            "APP_NAME": configuration.app.name,
            "BUNDLE_ID": configuration.app.bundleIdentifier,
            "TARGET": configuration.project.target ?? configuration.app.name,
            "SCHEME": configuration.project.scheme,
            "CONTAINER": configuration.project.container,
            "CONFIGURATION": configuration.project.configuration,
            "SCHEME_YAML": yamlString(configuration.project.scheme),
            "CONTAINER_YAML": yamlString(configuration.project.container),
            "CONFIGURATION_YAML": yamlString(configuration.project.configuration),
            "GITHUB_OWNER": configuration.github.owner,
            "GITHUB_REPOSITORY": configuration.github.repository,
            "FEED_URL": configuration.updates.feedURL,
            "SPARKLE_VERSION": configuration.updates.sparkleVersion,
            "APP_STYLE": configuration.app.style.rawValue,
            "SANDBOX_STATUS": configuration.app.sandboxed.map { $0 ? "enabled" : "disabled" } ?? "not detected",
            "RELEASE_MODE": configuration.distribution.releaseMode.rawValue,
            "TEMPLATE": configuration.project.template.rawValue,
            "MINIMUM_MACOS": configuration.app.minimumMacOS,
        ]
        guard markdown else { return raw }
        return raw.mapValues(markdownEscaped)
    }

    private func yamlString(_ value: String) -> String {
        let encoded = try? JSONEncoder().encode(value)
        return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func markdownEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
    }
}
