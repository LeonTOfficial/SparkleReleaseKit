import Foundation

public enum IntegrationError: LocalizedError {
    case missingPublicKey
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .missingPublicKey:
            "A Sparkle public EdDSA key is required before integration. Run generate_keys and add the printed public key to sparklekit.json."
        case .unsafePath(let path):
            "Refusing to write outside the project root: \(path)"
        }
    }
}

public struct Integrator {
    private let fileManager = FileManager.default

    public init() {}

    public func integrate(
        projectRoot: URL,
        configuration: SparkleKitConfiguration,
        apply: Bool
    ) throws -> IntegrationResult {
        guard !configuration.updates.publicEDKey.isEmpty else { throw IntegrationError.missingPublicKey }
        try ConfigurationStore().validate(configuration)

        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let renderer = TemplateRenderer(configuration: configuration)
        var desired: [String: Data] = [
            "SparkleReleaseKit/AppUpdater.swift": try renderer.render(named: "AppUpdater.swift.template"),
            "SparkleReleaseKit/INTEGRATION.md": try renderer.render(named: "INTEGRATION.md.template"),
            ".github/workflows/sparkle-release.yml": try renderer.render(named: "sparkle-release.yml.template"),
            "release-notes/next.md": try renderer.render(named: "release-notes.md.template"),
        ]
        desired[".gitignore"] = try updatedGitIgnore(at: root)

        var changes = try desired.keys.sorted().map { relativePath -> IntegrationChange in
            let destination = try safeURL(relativePath, root: root)
            let existing = try existingManagedData(at: destination)
            let kind: IntegrationChange.Kind = existing == desired[relativePath] ? .unchanged : (existing == nil ? .create : .update)
            return IntegrationChange(kind: kind, relativePath: relativePath, summary: summary(for: relativePath))
        }

        if let relativePlist = configuration.project.infoPlist {
            let plistURL = try safeURL(relativePlist, root: root)
            let status = try plistChangeStatus(url: plistURL, configuration: configuration)
            changes.append(.init(kind: status, relativePath: relativePlist, summary: "Configure the Sparkle feed and EdDSA public key."))
        }

        guard apply else {
            return IntegrationResult(applied: false, backupURL: nil, changes: changes)
        }

        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = try safeURL(".sparklekit/backups/\(stamp)", root: root)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        var created: [URL] = []
        var backedUp: [(source: URL, backup: URL)] = []

        do {
            let managedChanges = changes.filter { $0.kind != .unchanged }
                + [.init(kind: fileManager.fileExists(atPath: root.appendingPathComponent(".sparklekit/manifest.json").path) ? .update : .create,
                         relativePath: ".sparklekit/manifest.json",
                         summary: "Record files managed by SparkleReleaseKit.")]
            for change in managedChanges {
                let destination = try safeURL(change.relativePath, root: root)
                if fileManager.fileExists(atPath: destination.path) {
                    let backupURL = backup.appendingPathComponent(change.relativePath)
                    try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: destination, to: backupURL)
                    backedUp.append((destination, backupURL))
                } else {
                    created.append(destination)
                }
            }

            for (relativePath, data) in desired {
                let destination = try safeURL(relativePath, root: root)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }

            if let relativePlist = configuration.project.infoPlist {
                try patchInfoPlist(at: safeURL(relativePlist, root: root), configuration: configuration)
            }

            try writeManifest(changes: changes, configuration: configuration, root: root)
            return IntegrationResult(applied: true, backupURL: backup, changes: changes)
        } catch {
            for url in created.reversed() where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            for item in backedUp.reversed() {
                try? fileManager.removeItem(at: item.source)
                try? fileManager.createDirectory(at: item.source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.copyItem(at: item.backup, to: item.source)
            }
            throw error
        }
    }

    private func updatedGitIgnore(at root: URL) throws -> Data {
        let url = try safeURL(".gitignore", root: root)
        var text = ""
        if fileManager.fileExists(atPath: url.path) {
            guard let existing = BoundedFileReader.string(at: url, maximumBytes: 1_024 * 1_024) else {
                throw ConfigurationError.invalid(".gitignore must be a UTF-8 regular file no larger than 1 MiB")
            }
            text = existing
        }
        let entries = [".sparklekit/private/", ".sparklekit/backups/", ".sparklekit/releases/", "*.p8", "*.p12"]
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.contains("# SparkleReleaseKit private and generated data") {
            text += "\n# SparkleReleaseKit private and generated data\n"
        }
        for entry in entries where !text.split(separator: "\n").contains(Substring(entry)) {
            text += "\(entry)\n"
        }
        return Data(text.utf8)
    }

    private func plistChangeStatus(url: URL, configuration: SparkleKitConfiguration) throws -> IntegrationChange.Kind {
        guard let data = BoundedFileReader.data(at: url, maximumBytes: 1_024 * 1_024),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            return .update
        }
        let matches = dictionary["SUFeedURL"] as? String == configuration.updates.feedURL
            && dictionary["SUPublicEDKey"] as? String == configuration.updates.publicEDKey
            && dictionary["SUEnableAutomaticChecks"] as? Bool == configuration.updates.automaticChecks
            && dictionary["SUAutomaticallyUpdate"] as? Bool == configuration.updates.automaticDownloads
        return matches ? .unchanged : .update
    }

    private func patchInfoPlist(at url: URL, configuration: SparkleKitConfiguration) throws {
        guard let data = BoundedFileReader.data(at: url, maximumBytes: 1_024 * 1_024) else {
            throw ConfigurationError.invalid("Info.plist must be a regular file no larger than 1 MiB")
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw ConfigurationError.invalid("Info.plist is not a dictionary")
        }
        dictionary["SUFeedURL"] = configuration.updates.feedURL
        dictionary["SUPublicEDKey"] = configuration.updates.publicEDKey
        dictionary["SUEnableAutomaticChecks"] = configuration.updates.automaticChecks
        dictionary["SUAutomaticallyUpdate"] = configuration.updates.automaticDownloads
        let updated = try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
        try updated.write(to: url, options: .atomic)
    }

    private func writeManifest(
        changes: [IntegrationChange],
        configuration: SparkleKitConfiguration,
        root: URL
    ) throws {
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "integratedAt": ISO8601DateFormatter().string(from: Date()),
            "sparkleVersion": configuration.updates.sparkleVersion,
            "managedFiles": changes.filter { $0.relativePath != configuration.project.infoPlist }.map(\.relativePath),
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = try safeURL(".sparklekit/manifest.json", root: root)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func safeURL(_ relativePath: String, root: URL) throws -> URL {
        try ProjectPathResolver.resolve(relativePath, under: root, fileManager: fileManager)
    }

    private func existingManagedData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = BoundedFileReader.data(at: url, maximumBytes: 32 * 1_024 * 1_024) else {
            throw ConfigurationError.invalid("managed files must be regular files no larger than 32 MiB: \(url.lastPathComponent)")
        }
        return data
    }

    private func summary(for path: String) -> String {
        switch path {
        case "SparkleReleaseKit/AppUpdater.swift": "Add the minimal Sparkle updater controller."
        case "SparkleReleaseKit/INTEGRATION.md": "Add project-specific human and AI integration instructions."
        case ".github/workflows/sparkle-release.yml": "Add build, verification, and release preparation automation."
        case "release-notes/next.md": "Add the next-release notes template."
        case ".gitignore": "Exclude private keys, credentials, backups, and generated release files."
        default: "Configure SparkleReleaseKit."
        }
    }
}
