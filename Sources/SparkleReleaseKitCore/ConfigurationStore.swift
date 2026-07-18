import Foundation

public enum ConfigurationError: LocalizedError {
    case missing(URL)
    case unsupportedSchema(Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let url):
            "No SparkleReleaseKit configuration was found at \(url.path)."
        case .unsupportedSchema(let version):
            "Configuration schema version \(version) is not supported."
        case .invalid(let message):
            "The configuration is invalid: \(message)"
        }
    }
}

public struct ConfigurationStore: Sendable {
    public static let defaultFileName = "sparklekit.json"
    private static let maximumConfigurationBytes = 1_024 * 1_024

    public init() {}

    public func load(from url: URL) throws -> SparkleKitConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigurationError.missing(url)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size <= Self.maximumConfigurationBytes
        else {
            throw ConfigurationError.invalid("sparklekit.json must be a regular, non-symlink file no larger than 1 MiB")
        }
        let data = try Data(contentsOf: url)
        try validateRawDocument(data)
        var configuration = try JSONDecoder().decode(SparkleKitConfiguration.self, from: data)
        guard (1...SparkleKitConfiguration.currentSchemaVersion).contains(configuration.schemaVersion) else {
            throw ConfigurationError.unsupportedSchema(configuration.schemaVersion)
        }
        try validate(configuration, allowMissingPublicKey: true)
        configuration.schemaVersion = SparkleKitConfiguration.currentSchemaVersion
        return configuration
    }

    public func save(_ configuration: SparkleKitConfiguration, to url: URL) throws {
        var normalized = configuration
        normalized.schema = SparkleKitConfiguration.schemaURL
        normalized.schemaVersion = SparkleKitConfiguration.currentSchemaVersion
        try validate(normalized, allowMissingPublicKey: true)
        if FileManager.default.fileExists(atPath: url.path),
            try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        {
            throw ConfigurationError.invalid("refusing to replace a symbolic-link configuration file")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func validate(_ configuration: SparkleKitConfiguration, allowMissingPublicKey: Bool = false) throws {
        guard configuration.schema == SparkleKitConfiguration.schemaURL else {
            throw ConfigurationError.invalid("$schema must reference the published SparkleReleaseKit schema")
        }
        guard !configuration.app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            configuration.app.name.utf8.count <= 120,
            !containsControlCharacter(configuration.app.name)
        else {
            throw ConfigurationError.invalid("app.name must contain 1 to 120 printable bytes")
        }
        guard matches(configuration.app.bundleIdentifier, #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#) else {
            throw ConfigurationError.invalid("app.bundleIdentifier must be a reverse-DNS identifier")
        }
        guard matches(configuration.app.minimumMacOS, #"^[0-9]+(?:\.[0-9]+){1,2}$"#) else {
            throw ConfigurationError.invalid("app.minimumMacOS must be a dotted macOS version")
        }
        guard let feedURL = URL(string: configuration.updates.feedURL),
            configuration.updates.feedURL.utf8.count <= 2_048,
            feedURL.scheme?.lowercased() == "https",
            feedURL.host != nil,
            feedURL.user == nil,
            feedURL.password == nil,
            URLComponents(url: feedURL, resolvingAgainstBaseURL: false)?.query == nil,
            URLComponents(url: feedURL, resolvingAgainstBaseURL: false)?.fragment == nil
        else {
            throw ConfigurationError.invalid("updates.feedURL must be credential-free HTTPS without a query or fragment")
        }
        guard matches(configuration.github.owner, #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"#),
            matches(configuration.github.repository, #"^[A-Za-z0-9._-]{1,100}$"#),
            ![".", ".."].contains(configuration.github.repository)
        else {
            throw ConfigurationError.invalid("github.owner and github.repository are required")
        }
        guard isSafeRelativePath(configuration.project.container),
            !containsGitHubExpression(configuration.project.container),
            ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: configuration.project.container).pathExtension.lowercased())
        else {
            throw ConfigurationError.invalid("project.container must be a relative .xcodeproj or .xcworkspace path")
        }
        guard isSafeGitBranch(configuration.github.pagesBranch) else {
            throw ConfigurationError.invalid("github.pagesBranch must be a safe Git branch name")
        }
        guard !configuration.project.scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !configuration.project.configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            configuration.project.scheme.utf8.count <= 255,
            configuration.project.configuration.utf8.count <= 255,
            !containsControlCharacter(configuration.project.scheme),
            !containsControlCharacter(configuration.project.configuration),
            !containsGitHubExpression(configuration.project.scheme),
            !containsGitHubExpression(configuration.project.configuration)
        else {
            throw ConfigurationError.invalid("project.scheme and project.configuration are required")
        }
        if let infoPlist = configuration.project.infoPlist, !isSafeRelativePath(infoPlist) {
            throw ConfigurationError.invalid("project.infoPlist must stay inside the project root")
        }
        guard matches(configuration.updates.sparkleVersion, #"^[0-9]+\.[0-9]+\.[0-9]+$"#) else {
            throw ConfigurationError.invalid("updates.sparkleVersion must be a stable semantic version")
        }
        if !allowMissingPublicKey && configuration.updates.publicEDKey.isEmpty {
            throw ConfigurationError.invalid("updates.publicEDKey is missing; run Sparkle's generate_keys tool")
        }
        if !configuration.updates.publicEDKey.isEmpty {
            guard let key = Data(base64Encoded: configuration.updates.publicEDKey), key.count == 32 else {
                throw ConfigurationError.invalid("updates.publicEDKey must be Sparkle's 32-byte base64 Ed25519 public key")
            }
        }
        if let channel = configuration.updates.channel,
            !channel.isEmpty,
            !matches(channel, #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#)
        {
            throw ConfigurationError.invalid("updates.channel may contain only letters, numbers, dots, underscores, and hyphens")
        }
        guard
            Set(configuration.distribution.expectedArchitectures).count
                == configuration.distribution.expectedArchitectures.count
        else {
            throw ConfigurationError.invalid("distribution.expectedArchitectures cannot contain duplicates")
        }
        do {
            try ReleaseVerificationPolicy(distribution: configuration.distribution).validate()
        } catch {
            throw ConfigurationError.invalid(error.localizedDescription)
        }
    }

    private func validateRawDocument(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ConfigurationError.invalid("the root value must be an object")
        }
        try requireOnly(root, keys: ["$schema", "schemaVersion", "app", "project", "github", "updates", "distribution"], path: "root")
        try requireObject(root["app"], keys: ["name", "bundleIdentifier", "minimumMacOS", "style"], path: "app")
        try requireObject(root["project"], keys: ["container", "scheme", "configuration", "infoPlist"], path: "project")
        try requireObject(root["github"], keys: ["owner", "repository", "pagesBranch"], path: "github")
        try requireObject(
            root["updates"], keys: ["sparkleVersion", "feedURL", "publicEDKey", "automaticChecks", "automaticDownloads", "channel"],
            path: "updates")
        guard let schemaVersion = (root["schemaVersion"] as? NSNumber)?.intValue else {
            throw ConfigurationError.invalid("schemaVersion must be an integer")
        }
        switch schemaVersion {
        case 1:
            try requireObject(
                root["distribution"],
                keys: ["installer", "updateArchive", "notarization"],
                path: "distribution"
            )
        case SparkleKitConfiguration.currentSchemaVersion:
            try requireObject(
                root["distribution"],
                keys: [
                    "installer", "updateArchive", "releaseMode", "requireSparkleSignature",
                    "requireDeveloperID", "requireNotarization", "allowAdHocSigning",
                    "expectedArchitectures", "expectedTeamIdentifier",
                ],
                path: "distribution"
            )
        default:
            throw ConfigurationError.unsupportedSchema(schemaVersion)
        }
    }

    private func requireObject(_ value: Any?, keys: Set<String>, path: String) throws {
        guard let dictionary = value as? [String: Any] else {
            throw ConfigurationError.invalid("\(path) must be an object")
        }
        try requireOnly(dictionary, keys: keys, path: path)
    }

    private func requireOnly(_ dictionary: [String: Any], keys: Set<String>, path: String) throws {
        let unknown = Set(dictionary.keys).subtracting(keys).sorted()
        guard unknown.isEmpty else {
            let suspicious = unknown.filter {
                let key = $0.lowercased()
                return key.contains("private") || key.contains("secret") || key.contains("token") || key.contains("password")
                    || key.contains("certificate")
            }
            if !suspicious.isEmpty {
                throw ConfigurationError.invalid("secret-looking field(s) are forbidden at \(path): \(suspicious.joined(separator: ", "))")
            }
            throw ConfigurationError.invalid("unknown field(s) at \(path): \(unknown.joined(separator: ", "))")
        }
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return (try? NSRegularExpression(pattern: pattern).firstMatch(in: value, range: range)?.range == range) == true
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
            path.utf8.count <= 4_096,
            !path.hasPrefix("/"),
            !path.contains("\\"),
            !containsControlCharacter(path)
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty
            && !components.contains {
                $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.count > 255
            }
    }

    private func isSafeGitBranch(_ branch: String) -> Bool {
        guard matches(branch, #"^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$"#),
            !branch.contains(".."),
            !branch.contains("//"),
            !branch.contains("@{"),
            !branch.hasSuffix("/"),
            !branch.hasSuffix("."),
            !branch.hasSuffix(".lock")
        else {
            return false
        }
        return !branch.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    private func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func containsGitHubExpression(_ value: String) -> Bool {
        value.contains("${{")
    }
}
