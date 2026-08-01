import CryptoKit
import Foundation

public struct ProjectUpgradeChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case create
        case update
        case unchanged
        case preserved
        case conflict
    }

    public var kind: Kind
    public var relativePath: String
    public var summary: String
    public var diff: String?

    public init(
        kind: Kind,
        relativePath: String,
        summary: String,
        diff: String? = nil
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.summary = summary
        self.diff = diff
    }
}

public struct ProjectUpgradeConflict: Codable, Equatable, Sendable {
    public var relativePath: String
    public var reason: String
    public var currentSHA256: String?
    public var expectedSHA256: String?
    public var diff: String?

    public init(
        relativePath: String,
        reason: String,
        currentSHA256: String?,
        expectedSHA256: String?,
        diff: String?
    ) {
        self.relativePath = relativePath
        self.reason = reason
        self.currentSHA256 = currentSHA256
        self.expectedSHA256 = expectedSHA256
        self.diff = diff
    }
}

public struct ProjectUpgradeResult: Codable, Equatable, Sendable {
    public var applied: Bool
    public var fromSchemaVersion: Int
    public var toSchemaVersion: Int
    public var fromToolVersion: String
    public var toToolVersion: String
    public var migration: String
    public var backupPath: String?
    public var changes: [ProjectUpgradeChange]
    public var conflicts: [ProjectUpgradeConflict]

    public init(
        applied: Bool,
        fromSchemaVersion: Int,
        toSchemaVersion: Int,
        fromToolVersion: String,
        toToolVersion: String,
        migration: String,
        backupPath: String?,
        changes: [ProjectUpgradeChange],
        conflicts: [ProjectUpgradeConflict]
    ) {
        self.applied = applied
        self.fromSchemaVersion = fromSchemaVersion
        self.toSchemaVersion = toSchemaVersion
        self.fromToolVersion = fromToolVersion
        self.toToolVersion = toToolVersion
        self.migration = migration
        self.backupPath = backupPath
        self.changes = changes
        self.conflicts = conflicts
    }
}

public struct ProjectUpgrader {
    private static let migration = "schema-4-managed-files"
    private static let maximumManagedBytes = 32 * 1_024 * 1_024

    private let integrator: Integrator
    private let fileManager: FileManager

    public init() {
        integrator = Integrator()
        fileManager = .default
    }

    init(
        afterManagedWrite: @escaping (Int, String) throws -> Void
    ) {
        integrator = Integrator(afterManagedWrite: afterManagedWrite)
        fileManager = .default
    }

    public func upgrade(
        projectRoot: URL,
        apply: Bool
    ) throws -> ProjectUpgradeResult {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let configurationURL = try ProjectPathResolver.resolveForWrite(
            ConfigurationStore.defaultFileName,
            under: root
        )
        guard
            let rawConfiguration = BoundedFileReader.data(
                at: configurationURL,
                maximumBytes: 1_024 * 1_024
            )
        else {
            throw ConfigurationError.missing(configurationURL)
        }
        let originalSchema = try schemaVersion(in: rawConfiguration)
        let configuration = try ConfigurationStore().load(
            from: configurationURL
        )
        let desiredTemplates = try renderedTemplates(
            configuration: configuration
        )
        let ownership = try loadOwnership(root: root)
        let configuredHashes = Dictionary(
            uniqueKeysWithValues: configuration.management.managedFiles
                .compactMap { file in
                    file.originalTemplateSHA256.map {
                        (file.path, $0.lowercased())
                    }
                }
        )

        var templateChanges: [String: ProjectUpgradeChange] = [:]
        var conflicts: [ProjectUpgradeConflict] = []
        for path in desiredTemplates.keys.sorted() {
            guard let desired = desiredTemplates[path] else { continue }
            let destination = try ProjectPathResolver.resolveForWrite(
                path,
                under: root
            )
            let existing = try existingData(at: destination)
            guard let existing else {
                templateChanges[path] = .init(
                    kind: .create,
                    relativePath: path,
                    summary: "Create the current managed template.",
                    diff: UnifiedPreviewDiff.make(
                        path: path,
                        old: nil,
                        new: desired
                    )
                )
                continue
            }
            if existing == desired {
                templateChanges[path] = .init(
                    kind: .unchanged,
                    relativePath: path,
                    summary: "Managed template already matches this version."
                )
                continue
            }

            let currentHash = sha256(existing)
            let manifestHash = ownership[path]
            let configuredHash = configuredHashes[path]
            let metadataDisagrees =
                manifestHash != nil
                && configuredHash != nil
                && manifestHash != configuredHash
            let expectedHash = manifestHash ?? configuredHash
            let diff = UnifiedPreviewDiff.make(
                path: path,
                old: existing,
                new: desired
            )
            if !metadataDisagrees,
                expectedHash?.lowercased() == currentHash
            {
                templateChanges[path] = .init(
                    kind: .update,
                    relativePath: path,
                    summary:
                        "Update an unmodified managed template to the current version.",
                    diff: diff
                )
            } else {
                let reason: String
                if metadataDisagrees {
                    reason =
                        "Managed-file ownership metadata disagrees between the configuration and integration manifest."
                } else if expectedHash == nil {
                    reason =
                        "No trusted original template hash proves ownership."
                } else {
                    reason =
                        "The file differs from its recorded original template hash."
                }
                conflicts.append(
                    .init(
                        relativePath: path,
                        reason: reason,
                        currentSHA256: currentHash,
                        expectedSHA256: expectedHash,
                        diff: diff
                    )
                )
                templateChanges[path] = .init(
                    kind: .conflict,
                    relativePath: path,
                    summary:
                        "Preserve the manually changed file until the conflict is resolved.",
                    diff: diff
                )
            }
        }

        let desiredPaths = Set(desiredTemplates.keys)
        for managed in configuration.management.managedFiles
        where !desiredPaths.contains(managed.path) {
            let destination = try ProjectPathResolver.resolveForWrite(
                managed.path,
                under: root
            )
            if fileManager.fileExists(atPath: destination.path) {
                templateChanges[managed.path] = .init(
                    kind: .preserved,
                    relativePath: managed.path,
                    summary:
                        "Preserve a previously managed or project-specific file."
                )
            }
        }

        if !conflicts.isEmpty {
            let normalizedConfiguration = try ConfigurationStore()
                .encodedData(configuration, allowMissingPublicKey: true)
            if normalizedConfiguration != rawConfiguration {
                templateChanges[ConfigurationStore.defaultFileName] = .init(
                    kind: .update,
                    relativePath: ConfigurationStore.defaultFileName,
                    summary:
                        "Migrate configuration metadata after file conflicts are resolved."
                )
            }
            return result(
                applied: false,
                originalSchema: originalSchema,
                configuration: configuration,
                backupPath: nil,
                changes: Array(templateChanges.values),
                conflicts: conflicts
            )
        }

        let integration = try integrator.integrate(
            projectRoot: root,
            configuration: configuration,
            apply: apply
        )
        let converted = integration.changes.map { change in
            templateChanges[change.relativePath]
                ?? ProjectUpgradeChange(
                    kind: ProjectUpgradeChange.Kind(
                        integrationKind: change.kind
                    ),
                    relativePath: change.relativePath,
                    summary: change.summary
                )
        }
        let preserved = templateChanges.values.filter {
            change in
            change.kind == .preserved
                && !converted.contains { convertedChange in
                    convertedChange.relativePath == change.relativePath
                }
        }
        return result(
            applied: integration.applied,
            originalSchema: originalSchema,
            configuration: configuration,
            backupPath: integration.backupURL?.path,
            changes: converted + preserved,
            conflicts: []
        )
    }

    private func result(
        applied: Bool,
        originalSchema: Int,
        configuration: SparkleKitConfiguration,
        backupPath: String?,
        changes: [ProjectUpgradeChange],
        conflicts: [ProjectUpgradeConflict]
    ) -> ProjectUpgradeResult {
        ProjectUpgradeResult(
            applied: applied,
            fromSchemaVersion: originalSchema,
            toSchemaVersion: SparkleKitConfiguration.currentSchemaVersion,
            fromToolVersion: configuration.management.generatedByVersion,
            toToolVersion: SparkleReleaseKitVersion.current,
            migration: Self.migration,
            backupPath: backupPath,
            changes: changes.sorted { $0.relativePath < $1.relativePath },
            conflicts: conflicts.sorted {
                $0.relativePath < $1.relativePath
            }
        )
    }

    private func renderedTemplates(
        configuration: SparkleKitConfiguration
    ) throws -> [String: Data] {
        let renderer = TemplateRenderer(configuration: configuration)
        var desired: [String: Data] = [
            "SparkleReleaseKit/AppUpdater.swift":
                try renderer.render(named: "AppUpdater.swift.template"),
            "SparkleReleaseKit/INTEGRATION.md":
                try renderer.render(named: "INTEGRATION.md.template"),
            "release-notes/next.md":
                try renderer.render(named: "release-notes.md.template"),
        ]
        if configuration.project.generateWorkflow {
            desired[".github/workflows/sparkle-release.yml"] =
                try renderer.render(named: "sparkle-release.yml.template")
        }
        return desired
    }

    private func schemaVersion(in data: Data) throws -> Int {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let version = root["schemaVersion"] as? Int
        else {
            throw ConfigurationError.invalid(
                "sparklekit.json is missing schemaVersion"
            )
        }
        return version
    }

    private func loadOwnership(root: URL) throws -> [String: String] {
        let url = try ProjectPathResolver.resolveForWrite(
            ".sparklekit/manifest.json",
            under: root
        )
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        guard
            let data = BoundedFileReader.data(
                at: url,
                maximumBytes: 1_024 * 1_024
            ),
            let document = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let files = document["managedFiles"] as? [Any]
        else {
            throw ConfigurationError.invalid(
                ".sparklekit/manifest.json is malformed"
            )
        }
        var ownership: [String: String] = [:]
        for item in files {
            guard let entry = item as? [String: Any],
                let path = entry["path"] as? String,
                let hash = entry["sha256"] as? String,
                hash.range(
                    of: #"^[0-9a-fA-F]{64}$"#,
                    options: .regularExpression
                ) != nil
            else {
                // Schema v1 recorded path-only ownership. It is not enough to
                // authorize an overwrite during an upgrade.
                if item is String { continue }
                throw ConfigurationError.invalid(
                    ".sparklekit/manifest.json has invalid managed-file metadata"
                )
            }
            _ = try ProjectPathResolver.resolveForWrite(path, under: root)
            guard ownership[path] == nil else {
                throw ConfigurationError.invalid(
                    ".sparklekit/manifest.json contains duplicate managed-file paths"
                )
            }
            ownership[path] = hash.lowercased()
        }
        return ownership
    }

    private func existingData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard
            let data = BoundedFileReader.data(
                at: url,
                maximumBytes: Self.maximumManagedBytes
            )
        else {
            throw ConfigurationError.invalid(
                "managed project files must be regular non-symlink files no larger than 32 MiB"
            )
        }
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension ProjectUpgradeChange.Kind {
    init(integrationKind: IntegrationChange.Kind) {
        switch integrationKind {
        case .create:
            self = .create
        case .update:
            self = .update
        case .unchanged:
            self = .unchanged
        }
    }
}

private enum UnifiedPreviewDiff {
    private static let contextLines = 3
    private static let maximumChangedLines = 160
    private static let maximumBytes = 64 * 1_024

    static func make(path: String, old: Data?, new: Data) -> String? {
        guard let newText = String(data: new, encoding: .utf8),
            let oldText = old.flatMap({
                String(data: $0, encoding: .utf8)
            }) ?? (old == nil ? "" : nil)
        else {
            return "Binary content differs; no textual diff is available."
        }
        let oldLines = lines(oldText)
        let newLines = lines(newText)
        var prefix = 0
        while prefix < min(oldLines.count, newLines.count),
            oldLines[prefix] == newLines[prefix]
        {
            prefix += 1
        }
        var suffix = 0
        while suffix
            < min(
                oldLines.count - prefix,
                newLines.count - prefix
            ),
            oldLines[oldLines.count - suffix - 1]
                == newLines[newLines.count - suffix - 1]
        {
            suffix += 1
        }

        let contextStart = max(0, prefix - contextLines)
        let oldChangeEnd = oldLines.count - suffix
        let newChangeEnd = newLines.count - suffix
        let oldEnd = min(oldLines.count, oldChangeEnd + contextLines)
        let newEnd = min(newLines.count, newChangeEnd + contextLines)
        var output = "--- a/\(path)\n+++ b/\(path)\n"
        output += "@@ -\(contextStart + 1),\(oldEnd - contextStart) "
        output += "+\(contextStart + 1),\(newEnd - contextStart) @@\n"
        for line in oldLines[contextStart..<prefix] {
            output += " \(redact(line))\n"
        }
        var emitted = 0
        for line in oldLines[prefix..<oldChangeEnd] {
            guard emitted < maximumChangedLines else { break }
            output += "-\(redact(line))\n"
            emitted += 1
        }
        for line in newLines[prefix..<newChangeEnd] {
            guard emitted < maximumChangedLines else { break }
            output += "+\(redact(line))\n"
            emitted += 1
        }
        if emitted >= maximumChangedLines {
            output += "... [additional changed lines omitted] ...\n"
        }
        for line in newLines[newChangeEnd..<newEnd] {
            output += " \(redact(line))\n"
        }
        if output.utf8.count > maximumBytes {
            return String(output.prefix(maximumBytes))
                + "\n... [diff truncated] ..."
        }
        return output
    }

    private static func lines(_ value: String) -> [String] {
        value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    private static func redact(_ line: String) -> String {
        let lower = line.lowercased()
        let sensitiveMarkers = [
            "private_key", "private-key", "private key", "privatekey",
            "password", "secret", "token", "authorization", "bearer",
            "credential", "api_key", "api-key", "apikey",
        ]
        if sensitiveMarkers.contains(where: lower.contains) {
            return "[redacted potentially sensitive line]"
        }
        let printable = String(
            line.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? "\u{FFFD}" : Character($0)
            }
        )
        if printable.utf8.count <= 512 { return printable }
        return String(printable.prefix(512)) + "... [line truncated]"
    }
}
