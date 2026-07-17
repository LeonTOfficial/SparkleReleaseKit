import Foundation

public enum ReleasePreparationError: LocalizedError {
    case invalidVersion(String)
    case versionMismatch(expected: String, found: String)
    case unsafeURL(String)
    case unsafeKeychainAccount
    case outputExists(URL)
    case missingGenerateAppcast
    case invalidGenerateAppcast(URL)
    case generateAppcastFailed(String)
    case generatedAppcastMissing(URL)
    case archiveVerificationFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let version):
            "Release version '\(version)' is not a valid dotted version such as 1.2.0."
        case .versionMismatch(let expected, let found):
            "The requested release version is \(expected), but the app archive contains \(found)."
        case .unsafeURL(let value):
            "Release download URLs must use HTTPS: \(value)"
        case .unsafeKeychainAccount:
            "The Keychain account must be a non-empty printable value of at most 128 characters."
        case .outputExists(let url):
            "The release staging directory already exists at \(url.path). Pass --replace to archive it and create a fresh stage."
        case .missingGenerateAppcast:
            "Sparkle's official generate_appcast tool was not found. Pass --generate-appcast /path/to/Sparkle/bin/generate_appcast."
        case .invalidGenerateAppcast(let url):
            "Refusing to execute \(url.path). The selected executable must be named generate_appcast."
        case .generateAppcastFailed(let detail):
            "Sparkle's generate_appcast tool failed: \(detail)"
        case .generatedAppcastMissing(let url):
            "generate_appcast completed without creating \(url.path)."
        case .archiveVerificationFailed(let count):
            "The release archive failed \(count) verification check(s)."
        }
    }
}

public struct ReleasePreparationOptions: Sendable {
    public var version: String
    public var archiveURL: URL
    public var releaseNotesURL: URL?
    public var outputRootURL: URL?
    public var generateAppcastURL: URL?
    public var keychainAccount: String
    public var downloadURLPrefix: String?
    public var releaseNotesURLPrefix: String?
    public var phasedRolloutInterval: Int?
    public var replaceExisting: Bool

    public init(
        version: String,
        archiveURL: URL,
        releaseNotesURL: URL? = nil,
        outputRootURL: URL? = nil,
        generateAppcastURL: URL? = nil,
        keychainAccount: String = "ed25519",
        downloadURLPrefix: String? = nil,
        releaseNotesURLPrefix: String? = nil,
        phasedRolloutInterval: Int? = nil,
        replaceExisting: Bool = false
    ) {
        self.version = version
        self.archiveURL = archiveURL
        self.releaseNotesURL = releaseNotesURL
        self.outputRootURL = outputRootURL
        self.generateAppcastURL = generateAppcastURL
        self.keychainAccount = keychainAccount
        self.downloadURLPrefix = downloadURLPrefix
        self.releaseNotesURLPrefix = releaseNotesURLPrefix
        self.phasedRolloutInterval = phasedRolloutInterval
        self.replaceExisting = replaceExisting
    }
}

public struct ReleasePreparer: Sendable {
    private var fileManager: FileManager { .default }

    public init() {}

    public func prepare(
        projectRoot: URL,
        configuration: SparkleKitConfiguration,
        options: ReleasePreparationOptions
    ) throws -> ReleasePreparationResult {
        try ConfigurationStore().validate(configuration)
        try validateVersion(options.version)
        try validateKeychainAccount(options.keychainAccount)

        let archive = options.archiveURL.standardizedFileURL
        let inspection = try ReleaseVerifier().inspect(
            archiveURL: archive,
            expectedBundleIdentifier: configuration.app.bundleIdentifier,
            notarizationRequired: configuration.distribution.notarization == .required
        )
        let failures = inspection.diagnostics.filter { $0.severity == .failure }
        guard failures.isEmpty else {
            throw ReleasePreparationError.archiveVerificationFailed(failures.count)
        }
        guard let metadata = inspection.metadata else {
            throw ReleasePreparationError.archiveVerificationFailed(1)
        }
        guard metadata.shortVersion == options.version else {
            throw ReleasePreparationError.versionMismatch(expected: options.version, found: metadata.shortVersion)
        }

        let downloadPrefix = try validatedHTTPSPrefix(
            options.downloadURLPrefix
                ?? "https://github.com/\(configuration.github.owner)/\(configuration.github.repository)/releases/download/v\(options.version)/"
        )
        let releaseNotesURLPrefix = try options.releaseNotesURLPrefix.map(validatedHTTPSPrefix)

        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let outputRoot = try options.outputRootURL?.standardizedFileURL
            ?? ProjectPathResolver.resolve(".sparklekit/releases", under: root)
        let finalDirectory = outputRoot.appendingPathComponent("v\(options.version)").standardizedFileURL
        if fileManager.fileExists(atPath: finalDirectory.path), !options.replaceExisting {
            throw ReleasePreparationError.outputExists(finalDirectory)
        }

        let tool = try resolveGenerateAppcast(options.generateAppcastURL)
        let transactionRoot = outputRoot.appendingPathComponent(".preparing-\(UUID().uuidString)")
        try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        var shouldRemoveTransaction = true
        defer {
            if shouldRemoveTransaction { try? fileManager.removeItem(at: transactionRoot) }
        }

        let stagedArchive = transactionRoot.appendingPathComponent(archive.lastPathComponent)
        try fileManager.copyItem(at: archive, to: stagedArchive)
        let notesName = stagedArchive.deletingPathExtension().lastPathComponent + ".md"
        let stagedNotes = transactionRoot.appendingPathComponent(notesName)
        if let releaseNotes = options.releaseNotesURL {
            try fileManager.copyItem(at: releaseNotes.standardizedFileURL, to: stagedNotes)
        } else {
            let notes = "# \(configuration.app.name) \(options.version)\n\nSee the GitHub release for full details.\n"
            try Data(notes.utf8).write(to: stagedNotes, options: .atomic)
        }

        var arguments = [
            "--account", options.keychainAccount,
            "--download-url-prefix", downloadPrefix,
            "--embed-release-notes",
        ]
        if let prefix = releaseNotesURLPrefix {
            arguments += ["--release-notes-url-prefix", prefix]
        }
        if let channel = configuration.updates.channel, !channel.isEmpty {
            arguments += ["--channel", channel]
        }
        if let interval = options.phasedRolloutInterval {
            arguments += ["--phased-rollout-interval", String(interval)]
        }
        arguments.append(transactionRoot.path)

        let generation = try ProcessRunner().run(tool.path, arguments: arguments, directory: root)
        guard generation.status == 0 else {
            let detail = generation.standardError.isEmpty ? generation.standardOutput : generation.standardError
            throw ReleasePreparationError.generateAppcastFailed(detail)
        }

        let appcast = transactionRoot.appendingPathComponent("appcast.xml")
        guard fileManager.fileExists(atPath: appcast.path) else {
            throw ReleasePreparationError.generatedAppcastMissing(appcast)
        }
        let appcastResult = try AppcastValidator().validate(fileURL: appcast)
        let appcastFailures = appcastResult.diagnostics.filter { $0.severity == .failure }
        guard appcastFailures.isEmpty else {
            throw ReleasePreparationError.generateAppcastFailed("Generated appcast failed \(appcastFailures.count) validation check(s).")
        }

        var archivedPrevious: URL?
        if fileManager.fileExists(atPath: finalDirectory.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = try ProjectPathResolver.resolve(
                ".sparklekit/backups/releases/\(stamp)/v\(options.version)",
                under: root
            )
            try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: finalDirectory, to: backup)
            archivedPrevious = backup
        }

        do {
            try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: transactionRoot, to: finalDirectory)
            shouldRemoveTransaction = false
        } catch {
            if let archivedPrevious, !fileManager.fileExists(atPath: finalDirectory.path) {
                try? fileManager.moveItem(at: archivedPrevious, to: finalDirectory)
            }
            throw error
        }

        return ReleasePreparationResult(
            version: options.version,
            outputDirectory: finalDirectory,
            archiveURL: finalDirectory.appendingPathComponent(stagedArchive.lastPathComponent),
            appcastURL: finalDirectory.appendingPathComponent("appcast.xml"),
            metadata: metadata,
            diagnostics: inspection.diagnostics + appcastResult.diagnostics
        )
    }

    private func validateVersion(_ version: String) throws {
        let pattern = #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?$"#
        let range = NSRange(version.startIndex..., in: version)
        guard try NSRegularExpression(pattern: pattern).firstMatch(in: version, range: range)?.range == range else {
            throw ReleasePreparationError.invalidVersion(version)
        }
    }

    private func validatedHTTPSPrefix(_ value: String) throws -> String {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ReleasePreparationError.unsafeURL(value)
        }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let normalized = components.url?.absoluteString else {
            throw ReleasePreparationError.unsafeURL(value)
        }
        return normalized
    }

    private func validateKeychainAccount(_ account: String) throws {
        guard !account.isEmpty,
              account.count <= 128,
              !account.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ReleasePreparationError.unsafeKeychainAccount
        }
    }

    private func resolveGenerateAppcast(_ explicit: URL?) throws -> URL {
        var candidates: [URL] = []
        if let explicit {
            candidates.append(explicit.pathExtension.isEmpty
                ? explicit.appendingPathComponent("generate_appcast")
                : explicit)
            candidates.append(explicit)
        }
        if let environmentPath = ProcessInfo.processInfo.environment["SPARKLE_GENERATE_APPCAST"], !environmentPath.isEmpty {
            candidates.append(URL(fileURLWithPath: environmentPath))
        }
        for candidate in candidates.map({ $0.standardizedFileURL.resolvingSymlinksInPath() })
            where fileManager.isExecutableFile(atPath: candidate.path) {
            guard candidate.lastPathComponent == "generate_appcast" else {
                throw ReleasePreparationError.invalidGenerateAppcast(candidate)
            }
            return candidate
        }
        throw ReleasePreparationError.missingGenerateAppcast
    }
}
