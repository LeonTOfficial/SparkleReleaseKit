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
              var text = String(data: data, encoding: .utf8) else {
            throw TemplateError.missing(name)
        }
        for (placeholder, value) in replacements {
            text = text.replacingOccurrences(of: "{{\(placeholder)}}", with: value)
        }
        return Data(text.utf8)
    }

    private var replacements: [String: String] {
        [
            "APP_NAME": configuration.app.name,
            "BUNDLE_ID": configuration.app.bundleIdentifier,
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
            "MINIMUM_MACOS": configuration.app.minimumMacOS,
        ]
    }

    private func yamlString(_ value: String) -> String {
        let encoded = try? JSONEncoder().encode(value)
        return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
