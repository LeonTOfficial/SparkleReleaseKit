import CryptoKit
import Darwin
import Foundation

public enum IntegrationError: LocalizedError {
    case missingPublicKey
    case unsafePath(String)
    case unmanagedFile(String)
    case managedFileModified(String)
    case concurrentChange(String)
    case projectLocked
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .missingPublicKey:
            "A Sparkle public EdDSA key is required before integration. Run generate_keys and add the printed public key to sparklekit.json."
        case .unsafePath(let path):
            "Refusing to write through an unsafe path or outside the project root: \(path)"
        case .unmanagedFile(let path):
            "Refusing to overwrite \(path) because SparkleReleaseKit does not own the existing file."
        case .managedFileModified(let path):
            "Refusing to overwrite \(path) because it changed after SparkleReleaseKit generated it."
        case .concurrentChange(let path):
            "Refusing to continue because \(path) changed after the integration plan was created."
        case .projectLocked:
            "Another SparkleReleaseKit integration is already running for this project."
        case .rollbackFailed:
            "Integration failed and at least one touched path could not be restored safely. Inspect the backup before continuing."
        }
    }
}

public struct Integrator {
    private let fileManager: FileManager
    private let afterManagedWrite: (Int, String) throws -> Void

    public init() {
        fileManager = .default
        afterManagedWrite = { _, _ in }
    }

    init(afterManagedWrite: @escaping (Int, String) throws -> Void) {
        fileManager = .default
        self.afterManagedWrite = afterManagedWrite
    }

    public func integrate(
        projectRoot: URL,
        configuration: SparkleKitConfiguration,
        apply: Bool,
        allowConfigurationOnly: Bool = false
    ) throws -> IntegrationResult {
        let hasPublicKey = !configuration.updates.publicEDKey.isEmpty
        guard hasPublicKey || allowConfigurationOnly else {
            throw IntegrationError.missingPublicKey
        }
        try ConfigurationStore().validate(
            configuration,
            allowMissingPublicKey: allowConfigurationOnly
        )

        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let lock = apply ? try acquireLock(root: root) : nil
        defer { releaseLock(lock) }

        var desired: [String: Data] = [
            ConfigurationStore.defaultFileName: try ConfigurationStore().encodedData(
                configuration,
                allowMissingPublicKey: allowConfigurationOnly
            ),
        ]
        var generatedPaths: Set<String> = []
        if hasPublicKey {
            let renderer = TemplateRenderer(configuration: configuration)
            desired["SparkleReleaseKit/AppUpdater.swift"] =
                try renderer.render(named: "AppUpdater.swift.template")
            desired["SparkleReleaseKit/INTEGRATION.md"] =
                try renderer.render(named: "INTEGRATION.md.template")
            desired["release-notes/next.md"] =
                try renderer.render(named: "release-notes.md.template")
            desired[".gitignore"] = try updatedGitIgnore(at: root)
            if configuration.project.generateWorkflow {
                desired[".github/workflows/sparkle-release.yml"] =
                    try renderer.render(named: "sparkle-release.yml.template")
            }
            generatedPaths = Set(desired.keys).subtracting([
                ".gitignore", ConfigurationStore.defaultFileName,
            ])
            desired[".sparklekit/manifest.json"] = try manifestData(
                managedFiles: generatedPaths,
                desired: desired,
                configuration: configuration
            )
            if let relativePlist = configuration.project.infoPlist {
                desired[relativePlist] = try updatedInfoPlistData(
                    at: safeWriteURL(relativePlist, root: root),
                    configuration: configuration
                )
            }
        }
        let ownership = try loadOwnership(root: root)

        var snapshots: [String: Snapshot] = [:]
        let changes = try desired.keys.sorted().map { relativePath -> IntegrationChange in
            let destination = try safeWriteURL(relativePath, root: root)
            let existing = try existingManagedData(at: destination)
            snapshots[relativePath] = Snapshot(data: existing)
            if let existing,
               existing != desired[relativePath],
               generatedPaths.contains(relativePath)
            {
                try validateOwnership(
                    path: relativePath,
                    existing: existing,
                    ownership: ownership
                )
            }
            let kind: IntegrationChange.Kind =
                existing == desired[relativePath] ? .unchanged : (existing == nil ? .create : .update)
            return IntegrationChange(
                kind: kind,
                relativePath: relativePath,
                summary: summary(for: relativePath)
            )
        }

        guard apply else {
            return IntegrationResult(applied: false, backupURL: nil, changes: changes)
        }
        let pending = changes.filter { $0.kind != .unchanged }
        guard !pending.isEmpty else {
            return IntegrationResult(applied: false, backupURL: nil, changes: changes)
        }

        for change in pending {
            let current = try existingManagedData(at: safeWriteURL(change.relativePath, root: root))
            guard current == snapshots[change.relativePath]?.data else {
                throw IntegrationError.concurrentChange(change.relativePath)
            }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = try safeWriteURL(
            ".sparklekit/backups/\(stamp)-\(UUID().uuidString)",
            root: root
        )
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        var created: [String] = []
        var backedUp: [String] = []
        var written: [String] = []

        do {
            for change in pending {
                if snapshots[change.relativePath]?.data != nil {
                    let backupURL = backup.appendingPathComponent(change.relativePath)
                    try fileManager.createDirectory(
                        at: backupURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    guard let existing = snapshots[change.relativePath]?.data else {
                        throw IntegrationError.concurrentChange(change.relativePath)
                    }
                    try existing.write(to: backupURL, options: .atomic)
                    backedUp.append(change.relativePath)
                } else {
                    created.append(change.relativePath)
                }
            }

            for change in pending {
                let relativePath = change.relativePath
                guard let data = desired[relativePath] else { continue }
                let destination = try safeWriteURL(relativePath, root: root)
                let current = try existingManagedData(at: destination)
                guard current == snapshots[relativePath]?.data else {
                    throw IntegrationError.concurrentChange(relativePath)
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
                written.append(relativePath)
                guard try existingManagedData(at: destination) == data else {
                    throw IntegrationError.concurrentChange(relativePath)
                }
                try afterManagedWrite(written.count, relativePath)
            }
            return IntegrationResult(applied: true, backupURL: backup, changes: changes)
        } catch {
            let restored = rollback(
                created: created,
                backedUp: backedUp,
                written: written,
                desired: desired,
                backup: backup,
                root: root
            )
            if !restored { throw IntegrationError.rollbackFailed }
            throw error
        }
    }

    private struct Ownership {
        var paths: Set<String> = []
        var hashes: [String: String] = [:]
    }

    private struct Snapshot {
        var data: Data?
    }

    private struct Manifest: Codable {
        struct ManagedFile: Codable {
            var path: String
            var sha256: String
        }

        var schemaVersion: Int
        var sparkleVersion: String
        var managedFiles: [ManagedFile]
    }

    private func loadOwnership(root: URL) throws -> Ownership {
        let url = try safeWriteURL(".sparklekit/manifest.json", root: root)
        guard fileManager.fileExists(atPath: url.path) else { return Ownership() }
        guard let data = BoundedFileReader.data(at: url, maximumBytes: 1_024 * 1_024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["managedFiles"] as? [Any] else {
            throw ConfigurationError.invalid(".sparklekit/manifest.json is malformed")
        }

        var ownership = Ownership()
        for file in files {
            if let path = file as? String {
                ownership.paths.insert(path)
            } else if let entry = file as? [String: Any],
                      let path = entry["path"] as? String,
                      let hash = entry["sha256"] as? String
            {
                ownership.paths.insert(path)
                ownership.hashes[path] = hash
            } else {
                throw ConfigurationError.invalid(".sparklekit/manifest.json contains an invalid managed-file entry")
            }
        }
        return ownership
    }

    private func validateOwnership(
        path: String,
        existing: Data,
        ownership: Ownership
    ) throws {
        guard ownership.paths.contains(path) else {
            throw IntegrationError.unmanagedFile(path)
        }
        if let expectedHash = ownership.hashes[path],
           sha256(existing) != expectedHash {
            throw IntegrationError.managedFileModified(path)
        }
    }

    private func manifestData(
        managedFiles: Set<String>,
        desired: [String: Data],
        configuration: SparkleKitConfiguration
    ) throws -> Data {
        let entries = managedFiles.sorted().compactMap { path -> Manifest.ManagedFile? in
            guard let data = desired[path] else { return nil }
            return .init(path: path, sha256: sha256(data))
        }
        let manifest = Manifest(
            schemaVersion: 2,
            sparkleVersion: configuration.updates.sparkleVersion,
            managedFiles: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private func updatedGitIgnore(at root: URL) throws -> Data {
        let url = try safeWriteURL(".gitignore", root: root)
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

    private func updatedInfoPlistData(
        at url: URL,
        configuration: SparkleKitConfiguration
    ) throws -> Data {
        guard let data = BoundedFileReader.data(at: url, maximumBytes: 1_024 * 1_024) else {
            throw ConfigurationError.invalid("Info.plist must be a regular file no larger than 1 MiB")
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var dictionary = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw ConfigurationError.invalid("Info.plist is not a dictionary")
        }
        dictionary["SUFeedURL"] = configuration.updates.feedURL
        dictionary["SUPublicEDKey"] = configuration.updates.publicEDKey
        dictionary["SUEnableAutomaticChecks"] = configuration.updates.automaticChecks
        dictionary["SUAutomaticallyUpdate"] = configuration.updates.automaticDownloads
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: format,
            options: 0
        )
    }

    private func rollback(
        created: [String],
        backedUp: [String],
        written: [String],
        desired: [String: Data],
        backup: URL,
        root: URL
    ) -> Bool {
        var succeeded = true
        let writtenSet = Set(written)
        for path in created.reversed() where writtenSet.contains(path) {
            do {
                let destination = try safeWriteURL(path, root: root)
                guard try existingManagedData(at: destination) == desired[path] else {
                    succeeded = false
                    continue
                }
                try fileManager.removeItem(at: destination)
            } catch {
                succeeded = false
            }
        }
        for path in backedUp.reversed() where writtenSet.contains(path) {
            do {
                let destination = try safeWriteURL(path, root: root)
                guard try existingManagedData(at: destination) == desired[path],
                      let original = BoundedFileReader.data(
                        at: backup.appendingPathComponent(path),
                        maximumBytes: 32 * 1_024 * 1_024
                      ) else {
                    succeeded = false
                    continue
                }
                try original.write(to: destination, options: .atomic)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private struct ProjectLock {
        var descriptor: Int32
    }

    private func acquireLock(root: URL) throws -> ProjectLock {
        let url = try safeWriteURL(".sparklekit/integration.lock", root: root)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw IntegrationError.projectLocked }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw IntegrationError.projectLocked
        }
        return ProjectLock(descriptor: descriptor)
    }

    private func releaseLock(_ lock: ProjectLock?) {
        guard let lock else { return }
        _ = flock(lock.descriptor, LOCK_UN)
        close(lock.descriptor)
    }

    private func safeWriteURL(_ relativePath: String, root: URL) throws -> URL {
        try ProjectPathResolver.resolveForWrite(
            relativePath,
            under: root,
            fileManager: fileManager
        )
    }

    private func existingManagedData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        else { return nil }
        guard let data = BoundedFileReader.data(at: url, maximumBytes: 32 * 1_024 * 1_024) else {
            throw ConfigurationError.invalid("managed files must be regular files no larger than 32 MiB: \(url.lastPathComponent)")
        }
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func summary(for path: String) -> String {
        switch path {
        case "SparkleReleaseKit/AppUpdater.swift": "Add the minimal Sparkle updater controller."
        case "SparkleReleaseKit/INTEGRATION.md": "Add project-specific human and AI integration instructions."
        case ".github/workflows/sparkle-release.yml": "Add build, verification, and release preparation automation."
        case "release-notes/next.md": "Add the next-release notes template."
        case ".gitignore": "Exclude private keys, credentials, backups, and generated release files."
        case ConfigurationStore.defaultFileName: "Record the reviewed project and public update configuration."
        case ".sparklekit/manifest.json": "Record hashes for files managed by SparkleReleaseKit."
        default: "Configure SparkleReleaseKit."
        }
    }
}
