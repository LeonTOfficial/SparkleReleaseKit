import Darwin
import Foundation

public enum GenerateAppcastPathSource: String, Codable, Sendable {
    case explicitCLI = "explicit-cli"
    case environment
}

public struct GenerateAppcastTrustConfiguration: Codable, Equatable, Sendable {
    public var requireValidSignature: Bool
    public var expectedSigningIdentifier: String?
    public var expectedTeamIdentifier: String?
    public var designatedRequirement: String?
    public var allowedSHA256: [String]
    public var allowEnvironmentOverrideInCI: Bool

    public init(
        requireValidSignature: Bool = true,
        expectedSigningIdentifier: String? = nil,
        expectedTeamIdentifier: String? = nil,
        designatedRequirement: String? = nil,
        allowedSHA256: [String] = [],
        allowEnvironmentOverrideInCI: Bool = false
    ) {
        self.requireValidSignature = requireValidSignature
        self.expectedSigningIdentifier = expectedSigningIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.designatedRequirement = designatedRequirement
        self.allowedSHA256 = allowedSHA256
        self.allowEnvironmentOverrideInCI = allowEnvironmentOverrideInCI
    }
}

public struct GenerateAppcastTrustDecision: Codable, Equatable, Sendable {
    public var canonicalPath: String
    public var source: GenerateAppcastPathSource
    public var sha256: String
    public var signatureValid: Bool
    public var signingIdentifier: String?
    public var teamIdentifier: String?
    public var designatedRequirement: String?

    public init(
        canonicalPath: String,
        source: GenerateAppcastPathSource,
        sha256: String,
        signatureValid: Bool,
        signingIdentifier: String?,
        teamIdentifier: String?,
        designatedRequirement: String?
    ) {
        self.canonicalPath = canonicalPath
        self.source = source
        self.sha256 = sha256
        self.signatureValid = signatureValid
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.designatedRequirement = designatedRequirement
    }
}

public enum GenerateAppcastTrustError: LocalizedError, Equatable {
    case missingTool
    case environmentOverrideDeniedInCI
    case unsafePath
    case wrongFileName(String)
    case notRegularFile
    case notExecutable
    case untrustedOwner
    case writableByUntrustedUser
    case unsafeParentDirectory(String)
    case projectExecutionPermissionRequired
    case hashNotAllowed
    case invalidCodeSignature
    case signingIdentifierMismatch
    case teamIdentifierMismatch
    case designatedRequirementMismatch
    case incompleteCodeSignatureInspection

    public var errorDescription: String? {
        switch self {
        case .missingTool:
            "Sparkle's generate_appcast tool was not selected. Pass --generate-appcast or deliberately configure SPARKLE_GENERATE_APPCAST."
        case .environmentOverrideDeniedInCI:
            "SPARKLE_GENERATE_APPCAST is disabled in CI unless the configuration explicitly allows that path source."
        case .unsafePath:
            "The selected generate_appcast path could not be resolved safely."
        case .wrongFileName(let name):
            "The selected helper is named '\(name)', not generate_appcast."
        case .notRegularFile:
            "The selected generate_appcast helper is not a regular file."
        case .notExecutable:
            "The selected generate_appcast helper is not executable."
        case .untrustedOwner:
            "The selected generate_appcast helper is owned by an untrusted user."
        case .writableByUntrustedUser:
            "The selected generate_appcast helper is writable by an untrusted group or user."
        case .unsafeParentDirectory(let name):
            "The generate_appcast parent directory '\(name)' has unsafe ownership or write permissions."
        case .projectExecutionPermissionRequired:
            "The selected generate_appcast helper is inside the target project; pass --allow-project-execution only after reviewing it."
        case .hashNotAllowed:
            "The selected generate_appcast helper does not match the configured SHA-256 allowlist."
        case .invalidCodeSignature:
            "The selected generate_appcast helper does not have a valid strict code signature."
        case .signingIdentifierMismatch:
            "The selected generate_appcast helper has an unexpected signing identifier."
        case .teamIdentifierMismatch:
            "The selected generate_appcast helper has an unexpected Team ID."
        case .designatedRequirementMismatch:
            "The selected generate_appcast helper does not satisfy the configured designated requirement."
        case .incompleteCodeSignatureInspection:
            "Code-signature inspection for generate_appcast timed out or produced incomplete output."
        }
    }
}

public struct GenerateAppcastTrustPolicy: Sendable {
    private let processRunner: ProcessRunner
    private var fileManager: FileManager { .default }

    public init() {
        processRunner = ProcessRunner()
    }

    init(processRunner: ProcessRunner) {
        self.processRunner = processRunner
    }

    public func evaluate(
        explicitURL: URL?,
        projectRoot: URL,
        configuration: GenerateAppcastTrustConfiguration,
        allowProjectExecution: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GenerateAppcastTrustDecision {
        let selected: (url: URL, source: GenerateAppcastPathSource)
        if let explicitURL {
            selected = (candidateURL(explicitURL), .explicitCLI)
        } else if let value = environment["SPARKLE_GENERATE_APPCAST"], !value.isEmpty {
            if isCI(environment), !configuration.allowEnvironmentOverrideInCI {
                throw GenerateAppcastTrustError.environmentOverrideDeniedInCI
            }
            selected = (candidateURL(URL(fileURLWithPath: value)), .environment)
        } else {
            throw GenerateAppcastTrustError.missingTool
        }

        let canonical = try canonicalURL(selected.url)
        guard canonical.path.hasPrefix("/") else {
            throw GenerateAppcastTrustError.unsafePath
        }
        guard canonical.lastPathComponent == "generate_appcast" else {
            throw GenerateAppcastTrustError.wrongFileName(canonical.lastPathComponent)
        }
        try validateFile(at: canonical)
        try validateParentDirectories(of: canonical)

        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        if ProjectPathResolver.contains(canonical, in: root), !allowProjectExecution {
            throw GenerateAppcastTrustError.projectExecutionPermissionRequired
        }

        let digest = try FileDigest.sha256(of: canonical)
        let allowlist = Set(configuration.allowedSHA256.map { $0.lowercased() })
        if !allowlist.isEmpty, !allowlist.contains(digest) {
            throw GenerateAppcastTrustError.hashNotAllowed
        }

        let signature = try inspectSignature(
            at: canonical,
            environment: environment
        )
        if configuration.requireValidSignature, !signature.valid {
            throw GenerateAppcastTrustError.invalidCodeSignature
        }
        if let expected = configuration.expectedSigningIdentifier,
            signature.identifier != expected
        {
            throw GenerateAppcastTrustError.signingIdentifierMismatch
        }
        if let expected = configuration.expectedTeamIdentifier,
            signature.teamIdentifier != expected
        {
            throw GenerateAppcastTrustError.teamIdentifierMismatch
        }
        if let requirement = configuration.designatedRequirement {
            let result = try processRunner.run(
                "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "-R=\(requirement)", canonical.path],
                environment: helperEnvironment(environment),
                inheritEnvironment: false,
                timeout: 30
            )
            guard outputIsComplete(result) else {
                throw GenerateAppcastTrustError.incompleteCodeSignatureInspection
            }
            guard result.status == 0 else {
                throw GenerateAppcastTrustError.designatedRequirementMismatch
            }
        }

        return GenerateAppcastTrustDecision(
            canonicalPath: canonical.path,
            source: selected.source,
            sha256: digest,
            signatureValid: signature.valid,
            signingIdentifier: signature.identifier,
            teamIdentifier: signature.teamIdentifier,
            designatedRequirement: signature.designatedRequirement
        )
    }

    private struct SignatureInspection {
        var valid: Bool
        var identifier: String?
        var teamIdentifier: String?
        var designatedRequirement: String?
    }

    private func candidateURL(_ selected: URL) -> URL {
        let values = try? selected.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
            ? selected.appendingPathComponent("generate_appcast")
            : selected
    }

    private func canonicalURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw GenerateAppcastTrustError.unsafePath
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func validateFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw GenerateAppcastTrustError.unsafePath
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw GenerateAppcastTrustError.unsafePath
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw GenerateAppcastTrustError.notRegularFile
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw GenerateAppcastTrustError.notExecutable
        }
        guard trustedOwner(metadata.st_uid) else {
            throw GenerateAppcastTrustError.untrustedOwner
        }
        guard metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw GenerateAppcastTrustError.writableByUntrustedUser
        }
    }

    private func validateParentDirectories(of url: URL) throws {
        var current = url.deletingLastPathComponent()
        while true {
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0,
                (metadata.st_mode & S_IFMT) == S_IFDIR,
                trustedOwner(metadata.st_uid),
                metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
            else {
                throw GenerateAppcastTrustError.unsafeParentDirectory(
                    current.lastPathComponent.isEmpty ? "/" : current.lastPathComponent
                )
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return }
            current = parent
        }
    }

    private func trustedOwner(_ owner: uid_t) -> Bool {
        owner == 0 || owner == geteuid()
    }

    private func inspectSignature(
        at url: URL,
        environment ambient: [String: String]
    ) throws -> SignatureInspection {
        let environment = helperEnvironment(ambient)
        let verification = try processRunner.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "--verbose=4", url.path],
            environment: environment,
            inheritEnvironment: false,
            timeout: 30
        )
        let details = try processRunner.run(
            "/usr/bin/codesign",
            arguments: ["--display", "--verbose=4", "-r-", url.path],
            environment: environment,
            inheritEnvironment: false,
            timeout: 30
        )
        guard outputIsComplete(verification), outputIsComplete(details) else {
            throw GenerateAppcastTrustError.incompleteCodeSignatureInspection
        }
        let output = details.standardOutput + "\n" + details.standardError
        return SignatureInspection(
            valid: verification.status == 0 && details.status == 0,
            identifier: capture(#"(?m)^Identifier=([^\r\n]+)$"#, in: output),
            teamIdentifier: capture(#"(?m)^TeamIdentifier=([^\r\n]+)$"#, in: output)
                .flatMap { $0 == "not set" ? nil : $0 },
            designatedRequirement: capture(#"(?m)^designated => (.+)$"#, in: output)
        )
    }

    private func outputIsComplete(_ result: ProcessResult) -> Bool {
        !result.timedOut
            && !result.standardOutputTruncated
            && !result.standardErrorTruncated
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func helperEnvironment(_ ambient: [String: String]) -> [String: String] {
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"] {
            if let value = ambient[key], !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func isCI(_ environment: [String: String]) -> Bool {
        ["CI", "GITHUB_ACTIONS", "BUILDKITE", "JENKINS_URL", "TF_BUILD"].contains {
            guard let value = environment[$0]?.lowercased() else { return false }
            return !value.isEmpty && !["0", "false", "no"].contains(value)
        }
    }
}
