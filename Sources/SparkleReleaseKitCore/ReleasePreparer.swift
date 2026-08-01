import Foundation

public enum ReleasePreparationError: LocalizedError {
    case invalidVersion(String)
    case versionMismatch(expected: String, found: String)
    case unsafeURL(String)
    case unsafeKeychainAccount
    case outputExists(URL)
    case missingGenerateAppcast
    case invalidGenerateAppcast(URL)
    case projectGenerateAppcastRequiresPermission(URL)
    case generateAppcastFailed(String)
    case generatedAppcastMissing(URL)
    case archiveVerificationFailed(Int)
    case archiveChangedDuringPreparation
    case sparkleSignatureRequired
    case updateSignatureFailed(String)

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
        case .projectGenerateAppcastRequiresPermission(let url):
            "Refusing to execute \(url.path) from the target project without --allow-project-execution."
        case .generateAppcastFailed(let detail):
            "Sparkle's generate_appcast tool failed: \(detail)"
        case .generatedAppcastMissing(let url):
            "generate_appcast completed without creating \(url.path)."
        case .archiveVerificationFailed(let count):
            "The release archive failed \(count) verification check(s)."
        case .archiveChangedDuringPreparation:
            "The staged release archive changed while it was being prepared. Start again from an immutable build artifact."
        case .sparkleSignatureRequired:
            "Release preparation requires Sparkle EdDSA signing. Set distribution.requireSparkleSignature to true."
        case .updateSignatureFailed(let detail):
            "The generated Sparkle update signature could not be verified: \(detail)"
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
    public var allowProjectExecution: Bool
    public var allowGenerateAppcastEnvironmentInCI: Bool
    public var policyOverrides: ReleasePolicyOverrides
    public var environment: [String: String]

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
        replaceExisting: Bool = false,
        allowProjectExecution: Bool = false,
        allowGenerateAppcastEnvironmentInCI: Bool = false,
        policyOverrides: ReleasePolicyOverrides = .init(),
        environment: [String: String] = ProcessInfo.processInfo.environment
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
        self.allowProjectExecution = allowProjectExecution
        self.allowGenerateAppcastEnvironmentInCI =
            allowGenerateAppcastEnvironmentInCI
        self.policyOverrides = policyOverrides
        self.environment = environment
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
        let policy = try ReleaseVerificationPolicy(
            distribution: configuration.distribution,
            overrides: options.policyOverrides
        )
        guard policy.requireSparkleSignature else {
            throw ReleasePreparationError.sparkleSignatureRequired
        }

        let archive = options.archiveURL.standardizedFileURL
        let downloadPrefix = try validatedHTTPSPrefix(
            options.downloadURLPrefix
                ?? "https://github.com/\(configuration.github.owner)/\(configuration.github.repository)/releases/download/v\(options.version)/"
        )
        let releaseNotesURLPrefix = try options.releaseNotesURLPrefix.map(validatedHTTPSPrefix)

        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let outputRoot = try validatedOutputRoot(options.outputRootURL, projectRoot: root)
        let finalDirectory = outputRoot.appendingPathComponent("v\(options.version)").standardizedFileURL
        if fileManager.fileExists(atPath: finalDirectory.path), !options.replaceExisting {
            throw ReleasePreparationError.outputExists(finalDirectory)
        }

        var generateAppcastConfiguration =
            configuration.tools.generateAppcast
        if options.allowGenerateAppcastEnvironmentInCI {
            generateAppcastConfiguration.allowEnvironmentOverrideInCI = true
        }
        let generateAppcastTrust = try GenerateAppcastTrustPolicy().evaluate(
            explicitURL: options.generateAppcastURL,
            projectRoot: root,
            configuration: generateAppcastConfiguration,
            allowProjectExecution: options.allowProjectExecution,
            environment: options.environment
        )
        let tool = URL(fileURLWithPath: generateAppcastTrust.canonicalPath)
        let transactionRoot = outputRoot.appendingPathComponent(".preparing-\(UUID().uuidString)")
        try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        var shouldRemoveTransaction = true
        defer {
            if shouldRemoveTransaction { try? fileManager.removeItem(at: transactionRoot) }
        }

        let stagedArchive = transactionRoot.appendingPathComponent(archive.lastPathComponent)
        try fileManager.copyItem(at: archive, to: stagedArchive)
        let inspection = try ReleaseVerifier().inspect(
            archiveURL: stagedArchive,
            expectedBundleIdentifier: configuration.app.bundleIdentifier,
            policy: policy,
            rejectUnsigned: !policy.allowUnsigned
        )
        let failures = inspection.diagnostics.filter { $0.severity == .failure }
        guard failures.isEmpty else {
            throw ReleasePreparationError.archiveVerificationFailed(failures.count)
        }
        guard let metadata = inspection.metadata, let artifact = inspection.artifact else {
            throw ReleasePreparationError.archiveVerificationFailed(1)
        }
        guard metadata.shortVersion == options.version else {
            throw ReleasePreparationError.versionMismatch(expected: options.version, found: metadata.shortVersion)
        }

        let notesName = stagedArchive.deletingPathExtension().lastPathComponent + ".md"
        let stagedNotes = transactionRoot.appendingPathComponent(notesName)
        if let releaseNotes = options.releaseNotesURL {
            guard let notes = BoundedFileReader.data(
                at: releaseNotes.standardizedFileURL,
                maximumBytes: 10 * 1_024 * 1_024
            ) else {
                throw ReleasePreparationError.generateAppcastFailed(
                    "Release notes must be a regular, non-symlink file no larger than 10 MiB."
                )
            }
            try notes.write(to: stagedNotes, options: .atomic)
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

        let generation = try ProcessRunner().run(
            tool.path,
            arguments: arguments,
            directory: root,
            environment: helperEnvironment(options.environment),
            inheritEnvironment: false,
            timeout: 300
        )
        guard generation.status == 0,
              !generation.timedOut,
              !generation.standardOutputTruncated,
              !generation.standardErrorTruncated else {
            let detail = generation.standardError.isEmpty ? generation.standardOutput : generation.standardError
            let reason =
                generation.timedOut
                ? "The generator exceeded the 300-second timeout."
                : generation.standardOutputTruncated || generation.standardErrorTruncated
                    ? "The generator output exceeded the 8 MiB capture limit."
                    : detail
            throw ReleasePreparationError.generateAppcastFailed(reason)
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
        let signatureDiagnostic: Diagnostic
        do {
            signatureDiagnostic = try UpdateSignatureVerifier().verify(
                archiveURL: stagedArchive,
                appcast: appcastResult,
                publicEDKey: configuration.updates.publicEDKey,
                expectedBuildVersion: metadata.buildVersion
            )
        } catch {
            throw ReleasePreparationError.updateSignatureFailed(error.localizedDescription)
        }

        let finalAttributes = try fileManager.attributesOfItem(atPath: stagedArchive.path)
        let finalBytes = (finalAttributes[.size] as? NSNumber)?.int64Value ?? -1
        let finalDigest = try FileDigest.sha256(of: stagedArchive)
        guard finalBytes == artifact.archiveBytes, finalDigest == artifact.sha256 else {
            throw ReleasePreparationError.archiveChangedDuringPreparation
        }

        let checksum = transactionRoot.appendingPathComponent(stagedArchive.lastPathComponent + ".sha256")
        let checksumText = "\(finalDigest)  \(stagedArchive.lastPathComponent)\n"
        try Data(checksumText.utf8).write(to: checksum, options: .atomic)

        let manifest = ReleaseManifest(
            releaseMode: artifact.effectiveReleaseMode,
            metadata: metadata,
            archive: stagedArchive.lastPathComponent,
            artifact: artifact,
            sparkleSignatureVerified: true,
            unsignedOverrideUsed: policy.allowUnsigned && artifact.signingKind == .unsigned,
            appcast: appcast.lastPathComponent,
            generateAppcastTrust: generateAppcastTrust
        )
        let manifestURL = transactionRoot.appendingPathComponent("release-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

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
            checksumURL: finalDirectory.appendingPathComponent(checksum.lastPathComponent),
            manifestURL: finalDirectory.appendingPathComponent(manifestURL.lastPathComponent),
            metadata: metadata,
            diagnostics:
                inspection.diagnostics + [
                    generateAppcastDiagnostic(generateAppcastTrust)
                ] + appcastResult.diagnostics + [signatureDiagnostic],
            generateAppcastTrust: generateAppcastTrust
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
            components.fragment == nil
        else {
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
            !account.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ReleasePreparationError.unsafeKeychainAccount
        }
    }

    private func helperEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }

    private func generateAppcastDiagnostic(
        _ trust: GenerateAppcastTrustDecision
    ) -> Diagnostic {
        let identity = trust.signingIdentifier.map {
            " signing identifier \($0),"
        } ?? ""
        return .init(
            .pass,
            "generate_appcast trust",
            "Accepted \(trust.canonicalPath) from \(trust.source.rawValue);\(identity) SHA-256 \(trust.sha256).",
            id: "SRK4401",
            affectedComponent: trust.canonicalPath,
            evidence: trust.signatureValid
                ? "strict code signature valid"
                : "accepted by configured SHA-256 allowlist"
        )
    }

    private func validatedOutputRoot(_ explicit: URL?, projectRoot: URL) throws -> URL {
        guard let explicit else {
            return try ProjectPathResolver.resolve(".sparklekit/releases", under: projectRoot)
        }
        let resolved = explicit.standardizedFileURL.resolvingSymlinksInPath()
        if fileManager.fileExists(atPath: resolved.path) {
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ReleasePreparationError.outputExists(resolved)
            }
        }
        return resolved
    }
}
