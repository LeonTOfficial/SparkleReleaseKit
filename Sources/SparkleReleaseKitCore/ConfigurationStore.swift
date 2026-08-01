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
        guard let data = BoundedFileReader.data(at: url, maximumBytes: Self.maximumConfigurationBytes) else {
            throw ConfigurationError.invalid("sparklekit.json must be a regular, non-symlink file no larger than 1 MiB")
        }
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
        let data = try encodedData(configuration, allowMissingPublicKey: true)
        if FileManager.default.fileExists(atPath: url.path),
            try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        {
            throw ConfigurationError.invalid("refusing to replace a symbolic-link configuration file")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func encodedData(
        _ configuration: SparkleKitConfiguration,
        allowMissingPublicKey: Bool = false
    ) throws -> Data {
        var normalized = configuration
        normalized.schema = SparkleKitConfiguration.schemaURL
        normalized.schemaVersion = SparkleKitConfiguration.currentSchemaVersion
        normalized.management.generatedByVersion = SparkleReleaseKitVersion.current
        normalized.management.lastAppliedMigration =
            normalized.management.lastAppliedMigration ?? "schema-4-managed-files"
        normalized.management.knownTemplateVersion =
            normalized.management.knownTemplateVersion ?? 1
        try validate(normalized, allowMissingPublicKey: allowMissingPublicKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(normalized)
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
        if let target = configuration.project.target {
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                target.utf8.count <= 255,
                !containsControlCharacter(target),
                !containsGitHubExpression(target)
            else {
                throw ConfigurationError.invalid("project.target must be a printable target name")
            }
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
        try validateGenerateAppcastTrust(configuration.tools.generateAppcast)
        try validateManagement(configuration.management)
    }

    private func validateRawDocument(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ConfigurationError.invalid("the root value must be an object")
        }
        try requireOnly(
            root,
            keys: [
                "$schema", "schemaVersion", "app", "project", "github", "updates",
                "distribution", "tools", "management",
            ],
            path: "root"
        )
        try requireObject(
            root["app"],
            keys: ["name", "bundleIdentifier", "minimumMacOS", "style", "sandboxed"],
            path: "app"
        )
        try requireObject(
            root["project"],
            keys: [
                "container", "target", "scheme", "configuration", "infoPlist",
                "template", "generateWorkflow",
            ],
            path: "project"
        )
        try requireObject(root["github"], keys: ["owner", "repository", "pagesBranch"], path: "github")
        try requireObject(
            root["updates"], keys: ["sparkleVersion", "feedURL", "publicEDKey", "automaticChecks", "automaticDownloads", "channel"],
            path: "updates")
        guard let schemaVersion = (root["schemaVersion"] as? NSNumber)?.intValue else {
            throw ConfigurationError.invalid("schemaVersion must be an integer")
        }
        if schemaVersion < SparkleKitConfiguration.currentSchemaVersion,
            root["tools"] != nil || root["management"] != nil
        {
            throw ConfigurationError.invalid(
                "legacy configuration schemas cannot contain v4 tools or management fields"
            )
        }
        switch schemaVersion {
        case 1:
            try requireObject(
                root["distribution"],
                keys: ["installer", "updateArchive", "notarization"],
                path: "distribution"
            )
        case 2:
            try requireObject(
                root["project"],
                keys: ["container", "scheme", "configuration", "infoPlist"],
                path: "project"
            )
            try requireObject(
                root["app"],
                keys: ["name", "bundleIdentifier", "minimumMacOS", "style"],
                path: "app"
            )
            try requireObject(
                root["distribution"],
                keys: [
                    "installer", "updateArchive", "releaseMode", "requireSparkleSignature",
                    "requireDeveloperID", "requireNotarization", "allowAdHocSigning",
                    "expectedArchitectures", "expectedTeamIdentifier",
                ],
                path: "distribution"
            )
        case 3:
            try requireObject(
                root["distribution"],
                keys: [
                    "installer", "updateArchive", "releaseMode", "requireSparkleSignature",
                    "requireDeveloperID", "requireNotarization", "allowAdHocSigning",
                    "expectedArchitectures", "expectedTeamIdentifier",
                ],
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
            try requireObject(
                root["tools"],
                keys: ["generateAppcast"],
                path: "tools"
            )
            guard let tools = root["tools"] as? [String: Any] else {
                throw ConfigurationError.invalid("tools must be an object")
            }
            try requireObject(
                tools["generateAppcast"],
                keys: [
                    "requireValidSignature", "expectedSigningIdentifier",
                    "expectedTeamIdentifier", "designatedRequirement", "allowedSHA256",
                    "allowEnvironmentOverrideInCI",
                ],
                path: "tools.generateAppcast"
            )
            try requireObject(
                root["management"],
                keys: [
                    "generatedByVersion", "lastAppliedMigration",
                    "knownTemplateVersion", "managedFiles",
                ],
                path: "management"
            )
            guard let management = root["management"] as? [String: Any],
                let managedFiles = management["managedFiles"] as? [Any]
            else {
                throw ConfigurationError.invalid("management.managedFiles must be an array")
            }
            for (index, entry) in managedFiles.enumerated() {
                try requireObject(
                    entry,
                    keys: ["path", "originalTemplateSHA256", "templateVersion"],
                    path: "management.managedFiles[\(index)]"
                )
            }
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

    private func validateGenerateAppcastTrust(
        _ trust: GenerateAppcastTrustConfiguration
    ) throws {
        if !trust.requireValidSignature && trust.allowedSHA256.isEmpty {
            throw ConfigurationError.invalid(
                "tools.generateAppcast must require a valid signature unless a SHA-256 allowlist is configured"
            )
        }
        if let identifier = trust.expectedSigningIdentifier {
            guard !identifier.isEmpty,
                identifier.utf8.count <= 255,
                !containsControlCharacter(identifier)
            else {
                throw ConfigurationError.invalid(
                    "tools.generateAppcast.expectedSigningIdentifier must be printable"
                )
            }
        }
        if let team = trust.expectedTeamIdentifier {
            guard matches(team, #"^[A-Z0-9]{10}$"#) else {
                throw ConfigurationError.invalid(
                    "tools.generateAppcast.expectedTeamIdentifier must be a 10-character Apple Team ID"
                )
            }
        }
        if let requirement = trust.designatedRequirement {
            guard !requirement.isEmpty,
                requirement.utf8.count <= 4_096,
                !containsControlCharacter(requirement)
            else {
                throw ConfigurationError.invalid(
                    "tools.generateAppcast.designatedRequirement must contain 1 to 4096 printable bytes"
                )
            }
        }
        let hashes = trust.allowedSHA256.map { $0.lowercased() }
        guard hashes.count <= 32,
            hashes.allSatisfy({ matches($0, #"^[0-9a-f]{64}$"#) }),
            Set(hashes).count == hashes.count
        else {
            throw ConfigurationError.invalid(
                "tools.generateAppcast.allowedSHA256 must contain unique SHA-256 values"
            )
        }
    }

    private func validateManagement(
        _ management: SparkleKitConfiguration.Management
    ) throws {
        guard management.generatedByVersion == "unknown"
            || SemanticVersion(management.generatedByVersion) != nil
        else {
            throw ConfigurationError.invalid(
                "management.generatedByVersion must be a semantic version"
            )
        }
        if let migration = management.lastAppliedMigration {
            guard matches(migration, #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#) else {
                throw ConfigurationError.invalid(
                    "management.lastAppliedMigration contains unsafe characters"
                )
            }
        }
        if let version = management.knownTemplateVersion {
            guard version > 0 else {
                throw ConfigurationError.invalid(
                    "management.knownTemplateVersion must be positive"
                )
            }
        }
        let paths = management.managedFiles.map(\.path)
        guard Set(paths).count == paths.count else {
            throw ConfigurationError.invalid(
                "management.managedFiles cannot contain duplicate paths"
            )
        }
        for file in management.managedFiles {
            let hashIsValid = file.originalTemplateSHA256.map {
                matches($0.lowercased(), #"^[0-9a-f]{64}$"#)
            } ?? true
            guard isSafeRelativePath(file.path),
                hashIsValid,
                file.templateVersion.map({ $0 > 0 }) ?? true,
                file.originalTemplateSHA256 != nil || file.templateVersion == nil
            else {
                throw ConfigurationError.invalid(
                    "management.managedFiles contains an invalid path, hash, or template version"
                )
            }
        }
    }
}
