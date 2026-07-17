import Darwin
import Foundation
import SparkleReleaseKitCore

struct SparkleKitCLI {
    static let version = "0.1.1"

    private let configurationStore = ConfigurationStore()

    func run(arguments: [String]) throws {
        let command = arguments.first ?? "help"
        let rest = Array(arguments.dropFirst())

        switch command {
        case "setup": try setup(rest)
        case "doctor": try doctor(rest)
        case "integrate": try integrate(rest)
        case "test": try test(rest)
        case "verify": try verify(rest)
        case "validate-feed": try validateFeed(rest)
        case "prepare-release": try prepareRelease(rest)
        case "version", "--version", "-v":
            guard rest.isEmpty else { throw CLIError.unexpectedArgument(rest[0]) }
            print("SparkleReleaseKit \(Self.version) (Sparkle \(SparkleKitConfiguration.supportedSparkleVersion))")
        case "help", "--help", "-h":
            guard rest.isEmpty else { throw CLIError.unexpectedArgument(rest[0]) }
            printHelp()
        default: throw CLIError.unknownCommand(command)
        }
    }

    private func setup(_ arguments: [String]) throws {
        let options = try Options(
            arguments,
            valueOptions: ["owner", "repo", "app-name", "bundle-id", "scheme", "feed-url", "public-key"],
            booleanFlags: ["apply", "json"]
        )
        try options.rejectExtraPositionals(maximum: 1)
        let root = URL(fileURLWithPath: options.positionals.first ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        let json = options.flag("json")
        if !json {
            header("Set up secure Sparkle updates")
            info("Inspecting \(root.path)")
        }

        let detected = try ProjectDetector().detect(at: root)
        let owner = try resolvedRequiredValue(
            options.value("owner") ?? detected.githubOwner,
            label: "GitHub owner",
            defaultValue: detected.githubOwner
        )
        let repository = try resolvedRequiredValue(
            options.value("repo") ?? detected.githubRepository,
            label: "GitHub repository",
            defaultValue: detected.githubRepository ?? detected.rootURL.lastPathComponent
        )
        let appName = options.value("app-name") ?? detected.appName
        let bundleID = options.value("bundle-id") ?? detected.bundleIdentifier
        let scheme = options.value("scheme") ?? detected.scheme
        let publicKey = options.value("public-key") ?? ""
        let feedURL = options.value("feed-url")
            ?? "https://\(owner.lowercased()).github.io/\(repository)/appcast.xml"
        let container = relativePath(detected.containerURL, to: detected.rootURL)
        let infoPlist = detected.infoPlistURL.map { relativePath($0, to: detected.rootURL) }

        let configuration = SparkleKitConfiguration(
            app: .init(name: appName, bundleIdentifier: bundleID, minimumMacOS: detected.minimumMacOS, style: detected.style),
            project: .init(container: container, scheme: scheme, infoPlist: infoPlist),
            github: .init(owner: owner, repository: repository),
            updates: .init(feedURL: feedURL, publicEDKey: publicKey)
        )
        let configURL = detected.rootURL.appendingPathComponent(ConfigurationStore.defaultFileName)
        try configurationStore.save(configuration, to: configURL)

        var integration: IntegrationResult?
        if options.flag("apply") {
            integration = try Integrator().integrate(projectRoot: detected.rootURL, configuration: configuration, apply: true)
        }

        if json {
            try printJSON(SetupReport(configurationPath: configURL, configuration: configuration, integration: integration))
            return
        }

        success("Created \(configURL.path)")
        detail("App", configuration.app.name)
        detail("Target style", configuration.app.style.rawValue)
        detail("Xcode container", configuration.project.container)
        detail("Feed", configuration.updates.feedURL)

        if publicKey.isEmpty {
            warning("The public EdDSA key is still missing.")
            print("\nRun Sparkle's official generate_keys tool once, then add only its printed public key to updates.publicEDKey in sparklekit.json.")
            print("After that, run: sparklekit integrate \(shellQuoted(detected.rootURL.path)) --apply")
        } else if integration != nil {
            success("Integration files were applied.")
            print("Open SparkleReleaseKit/INTEGRATION.md and complete the two explicit Xcode steps.")
        } else {
            print("\nPreview the integration with: sparklekit integrate \(shellQuoted(detected.rootURL.path))")
        }
    }

    private func doctor(_ arguments: [String]) throws {
        let options = try Options(arguments, booleanFlags: ["json"])
        try options.rejectExtraPositionals(maximum: 1)
        let root = projectRoot(options)
        let loaded = loadConfigurationForDiagnostics(root)
        var diagnostics = Doctor().inspect(
            projectRoot: root,
            configuration: loaded.configuration,
            configurationError: loaded.error
        )
        let failures = diagnostics.filter { $0.severity == .failure }

        if options.flag("json") {
            try printJSON(DiagnosticReport(command: "doctor", success: failures.isEmpty, diagnostics: diagnostics))
        } else {
            header("SparkleReleaseKit doctor")
            printDiagnostics(diagnostics)
            print("\n\(diagnostics.count - failures.count) checks passed or need attention; \(failures.count) failed.")
        }
        diagnostics.removeAll(keepingCapacity: false)
        if !failures.isEmpty { throw CLIError.diagnosticsFailed(failures.count, jsonWasPrinted: options.flag("json")) }
    }

    private func integrate(_ arguments: [String]) throws {
        let options = try Options(arguments, booleanFlags: ["apply", "json"])
        try options.rejectExtraPositionals(maximum: 1)
        let root = projectRoot(options)
        let configuration = try configurationStore.load(from: root.appendingPathComponent(ConfigurationStore.defaultFileName))
        let result = try Integrator().integrate(projectRoot: root, configuration: configuration, apply: options.flag("apply"))

        if options.flag("json") {
            try printJSON(result)
            return
        }
        header(result.applied ? "Apply Sparkle integration" : "Preview Sparkle integration")
        printChanges(result.changes)
        if result.applied {
            success("Integration files were written successfully.")
            if let backup = result.backupURL { info("Backup: \(backup.path)") }
            print("\nOpen SparkleReleaseKit/INTEGRATION.md, complete the two Xcode steps, then run sparklekit doctor.")
        } else {
            print("\nNo files were changed. Apply this plan with: sparklekit integrate \(shellQuoted(root.path)) --apply")
        }
    }

    private func test(_ arguments: [String]) throws {
        let options = try Options(arguments, booleanFlags: ["json"])
        try options.rejectExtraPositionals(maximum: 1)
        let root = projectRoot(options)
        let configuration = try configurationStore.load(from: root.appendingPathComponent(ConfigurationStore.defaultFileName))
        var diagnostics = Doctor().inspect(projectRoot: root, configuration: configuration)
        if !diagnostics.contains(where: { $0.severity == .failure }) {
            diagnostics += try XcodeBuildValidator().validate(projectRoot: root, configuration: configuration)
        }
        let failures = diagnostics.filter { $0.severity == .failure }
        if options.flag("json") {
            try printJSON(DiagnosticReport(command: "test", success: failures.isEmpty, diagnostics: diagnostics))
        } else {
            header("Test the complete integration")
            printDiagnostics(diagnostics)
        }
        if !failures.isEmpty { throw CLIError.diagnosticsFailed(failures.count, jsonWasPrinted: options.flag("json")) }
    }

    private func verify(_ arguments: [String]) throws {
        let options = try Options(arguments, valueOptions: ["project"], booleanFlags: ["json"])
        try options.rejectExtraPositionals(maximum: 1)
        guard let archivePath = options.positionals.first else { throw CLIError.missingArgument("archive path") }
        let root = URL(fileURLWithPath: options.value("project") ?? FileManager.default.currentDirectoryPath).standardizedFileURL
        let configurationURL = root.appendingPathComponent(ConfigurationStore.defaultFileName)
        let configuration = FileManager.default.fileExists(atPath: configurationURL.path)
            ? try configurationStore.load(from: configurationURL)
            : nil
        let result = try ReleaseVerifier().inspect(
            archiveURL: URL(fileURLWithPath: archivePath),
            expectedBundleIdentifier: configuration?.app.bundleIdentifier,
            notarizationRequired: configuration?.distribution.notarization == .required
        )
        let failures = result.diagnostics.filter { $0.severity == .failure }
        if options.flag("json") {
            try printJSON(result)
        } else {
            header("Verify release archive")
            printDiagnostics(result.diagnostics)
        }
        if !failures.isEmpty { throw CLIError.diagnosticsFailed(failures.count, jsonWasPrinted: options.flag("json")) }
    }

    private func validateFeed(_ arguments: [String]) throws {
        let options = try Options(arguments, booleanFlags: ["json"])
        try options.rejectExtraPositionals(maximum: 1)
        guard let path = options.positionals.first else { throw CLIError.missingArgument("appcast.xml path") }
        let result = try AppcastValidator().validate(fileURL: URL(fileURLWithPath: path))
        let failures = result.diagnostics.filter { $0.severity == .failure }
        if options.flag("json") {
            try printJSON(result)
        } else {
            header("Validate Sparkle appcast")
            printDiagnostics(result.diagnostics)
            detail("Items", String(result.itemCount))
            detail("Versions", result.versions.joined(separator: ", "))
        }
        if !failures.isEmpty { throw CLIError.diagnosticsFailed(failures.count, jsonWasPrinted: options.flag("json")) }
    }

    private func prepareRelease(_ arguments: [String]) throws {
        let options = try Options(
            arguments,
            valueOptions: [
                "version", "project", "notes", "generate-appcast", "key-account",
                "download-url-prefix", "release-notes-url-prefix", "phased-rollout", "output",
            ],
            booleanFlags: ["replace", "json"]
        )
        try options.rejectExtraPositionals(maximum: 1)
        guard let archivePath = options.positionals.first else { throw CLIError.missingArgument("archive path") }
        guard let version = options.value("version") else { throw CLIError.missingArgument("--version") }
        let root = URL(fileURLWithPath: options.value("project") ?? FileManager.default.currentDirectoryPath).standardizedFileURL
        let configuration = try configurationStore.load(from: root.appendingPathComponent(ConfigurationStore.defaultFileName))
        let result = try ReleasePreparer().prepare(
            projectRoot: root,
            configuration: configuration,
            options: .init(
                version: version,
                archiveURL: URL(fileURLWithPath: archivePath),
                releaseNotesURL: options.value("notes").map(URL.init(fileURLWithPath:)),
                outputRootURL: options.value("output").map(URL.init(fileURLWithPath:)),
                generateAppcastURL: options.value("generate-appcast").map(URL.init(fileURLWithPath:)),
                keychainAccount: options.value("key-account") ?? "ed25519",
                downloadURLPrefix: options.value("download-url-prefix"),
                releaseNotesURLPrefix: options.value("release-notes-url-prefix"),
                phasedRolloutInterval: try options.integer("phased-rollout"),
                replaceExisting: options.flag("replace")
            )
        )
        if options.flag("json") {
            try printJSON(result)
        } else {
            header("Prepare signed Sparkle release")
            printDiagnostics(result.diagnostics)
            success("Prepared \(result.metadata.appName) \(result.version)")
            detail("Stage", result.outputDirectory.path)
            detail("Archive", result.archiveURL.lastPathComponent)
            detail("Appcast", result.appcastURL.lastPathComponent)
            print("\nReview this staging directory before uploading any asset or publishing a release.")
        }
    }

    private func projectRoot(_ options: Options) -> URL {
        URL(fileURLWithPath: options.positionals.first ?? FileManager.default.currentDirectoryPath).standardizedFileURL
    }

    private func loadConfigurationForDiagnostics(_ root: URL) -> (configuration: SparkleKitConfiguration?, error: String?) {
        let url = root.appendingPathComponent(ConfigurationStore.defaultFileName)
        do {
            return (try configurationStore.load(from: url), nil)
        } catch {
            return (nil, FileManager.default.fileExists(atPath: url.path) ? error.localizedDescription : nil)
        }
    }

    private func resolvedRequiredValue(_ value: String?, label: String, defaultValue: String?) throws -> String {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        guard isatty(STDIN_FILENO) != 0 else { throw CLIError.nonInteractiveValueRequired(label) }
        return prompt(label, defaultValue: defaultValue ?? "")
    }

    private func relativePath(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    private func printChanges(_ changes: [IntegrationChange]) {
        for change in changes {
            let marker = switch change.kind {
            case .create: "+"
            case .update: "~"
            case .unchanged: "="
            }
            print("  \(marker) \(change.relativePath)  \(change.summary)")
        }
    }

    private func printDiagnostics(_ diagnostics: [Diagnostic]) {
        for diagnostic in diagnostics {
            let marker = switch diagnostic.severity {
            case .pass: "PASS"
            case .warning: "WARN"
            case .failure: "FAIL"
            }
            print("\n[\(marker)] \(diagnostic.title)")
            print("       \(diagnostic.detail)")
            if let remediation = diagnostic.remediation { print("       Fix: \(remediation)") }
        }
    }

    private func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func prompt(_ label: String, defaultValue: String) -> String {
        let suffix = defaultValue.isEmpty ? "" : " [\(defaultValue)]"
        print("\(label)\(suffix): ", terminator: "")
        return readLine().flatMap { $0.isEmpty ? nil : $0 } ?? defaultValue
    }

    private func header(_ title: String) {
        print("\nSparkleReleaseKit")
        print("\(title)\n")
    }

    private func success(_ message: String) { print("\nSuccess: \(message)") }
    private func warning(_ message: String) { print("\nWarning: \(message)") }
    private func info(_ message: String) { print("  \(message)") }
    private func detail(_ label: String, _ value: String) {
        print("  \(label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(value)")
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func printHelp() {
        print("""
        SparkleReleaseKit \(Self.version)
        Add secure Sparkle updates to a macOS app with GitHub Releases in minutes.

        USAGE
          sparklekit setup [project-path] [options]
          sparklekit integrate [project-path] [--apply] [--json]
          sparklekit doctor [project-path] [--json]
          sparklekit test [project-path] [--json]
          sparklekit verify <archive.zip|archive.dmg> [--project path] [--json]
          sparklekit validate-feed <appcast.xml> [--json]
          sparklekit prepare-release <archive> --version X.Y.Z [options]

        SETUP OPTIONS
          --owner VALUE       GitHub account or organization
          --repo VALUE        GitHub repository name
          --app-name VALUE    User-facing application name
          --bundle-id VALUE   Reverse-DNS bundle identifier
          --scheme VALUE      Shared Xcode scheme
          --feed-url VALUE    HTTPS URL to appcast.xml
          --public-key VALUE  Sparkle EdDSA public key (never the private key)
          --apply             Apply generated integration files immediately
          --json              Emit stable, machine-readable JSON

        PREPARE-RELEASE OPTIONS
          --version VALUE             Version embedded in the app archive
          --project PATH              Project containing sparklekit.json
          --notes PATH                Markdown release notes
          --generate-appcast PATH     Official Sparkle generate_appcast tool
          --key-account VALUE         Keychain account (default: ed25519)
          --download-url-prefix URL   HTTPS release-asset prefix
          --release-notes-url-prefix URL
          --phased-rollout SECONDS    Sparkle phased rollout interval
          --output PATH               Release staging root
          --replace                   Archive an existing stage and replace it
          --json                      Emit stable, machine-readable JSON

        SAFE DEFAULTS
          integrate only previews changes until --apply is supplied.
          prepare-release reads the private EdDSA key from macOS Keychain and
          never accepts private key material in sparklekit.json.

        EXIT CODES
          0  Success
          1  Unexpected runtime or tool failure
          2  One or more validation checks failed
          64 Invalid command usage or missing input
          65 Invalid configuration data
          66 Target project was not found or could not be detected
          78 Unsafe or incomplete integration state

        DOCUMENTATION
          https://leontofficial.github.io/SparkleReleaseKit/
        """)
    }
}

private struct SetupReport: Encodable {
    var configurationPath: URL
    var configuration: SparkleKitConfiguration
    var integration: IntegrationResult?
}

private struct DiagnosticReport: Encodable {
    var command: String
    var success: Bool
    var diagnostics: [Diagnostic]
}

struct Options {
    var positionals: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(
        _ arguments: [String],
        valueOptions: Set<String> = [],
        booleanFlags: Set<String> = []
    ) throws {
        var index = 0
        var optionsEnded = false
        var seen: Set<String> = []
        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded {
                positionals.append(argument)
                index += 1
            } else if argument == "--" {
                optionsEnded = true
                index += 1
            } else if argument.hasPrefix("--") {
                let body = String(argument.dropFirst(2))
                if let separator = body.firstIndex(of: "=") {
                    let key = String(body[..<separator])
                    let value = String(body[body.index(after: separator)...])
                    guard valueOptions.contains(key) else {
                        if booleanFlags.contains(key) { throw CLIError.invalidValue(key, value) }
                        throw CLIError.unknownOption(key)
                    }
                    guard !value.isEmpty else { throw CLIError.missingArgument("value for --\(key)") }
                    guard seen.insert(key).inserted else { throw CLIError.duplicateOption(key) }
                    values[key] = value
                    index += 1
                } else if booleanFlags.contains(body) {
                    guard seen.insert(body).inserted else { throw CLIError.duplicateOption(body) }
                    flags.insert(body)
                    index += 1
                } else if valueOptions.contains(body),
                          index + 1 < arguments.count,
                          arguments[index + 1] != "--",
                          !arguments[index + 1].hasPrefix("--") {
                    guard seen.insert(body).inserted else { throw CLIError.duplicateOption(body) }
                    values[body] = arguments[index + 1]
                    index += 2
                } else if valueOptions.contains(body) {
                    throw CLIError.missingArgument("value for --\(body)")
                } else {
                    throw CLIError.unknownOption(body)
                }
            } else {
                positionals.append(argument)
                index += 1
            }
        }
    }

    func value(_ key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }

    func flag(_ key: String) -> Bool { flags.contains(key) }

    func integer(_ key: String) throws -> Int? {
        guard let value = value(key) else { return nil }
        guard let number = Int(value), number > 0 else { throw CLIError.invalidValue(key, value) }
        return number
    }

    func rejectExtraPositionals(maximum: Int) throws {
        guard positionals.count <= maximum else {
            throw CLIError.unexpectedArgument(positionals[maximum])
        }
    }
}

protocol SparkleKitExitCodeError: Error {
    var exitCode: Int32 { get }
    var suppressTextOutput: Bool { get }
}

enum CLIError: LocalizedError, SparkleKitExitCodeError {
    case unknownCommand(String)
    case unknownOption(String)
    case duplicateOption(String)
    case unexpectedArgument(String)
    case missingArgument(String)
    case invalidValue(String, String)
    case nonInteractiveValueRequired(String)
    case diagnosticsFailed(Int, jsonWasPrinted: Bool)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command): "Unknown command '\(command)'. Run sparklekit help."
        case .unknownOption(let option): "Unknown option '--\(option)'. Run sparklekit help."
        case .duplicateOption(let option): "Option '--\(option)' was supplied more than once."
        case .unexpectedArgument(let argument): "Unexpected argument '\(argument)'. Run sparklekit help."
        case .missingArgument(let argument): "Missing required \(argument)."
        case .invalidValue(let key, let value): "Invalid value '\(value)' for --\(key)."
        case .nonInteractiveValueRequired(let label): "\(label) is required in non-interactive mode. Pass it explicitly."
        case .diagnosticsFailed(let count, _): "\(count) required check(s) failed."
        }
    }

    var exitCode: Int32 {
        switch self {
        case .diagnosticsFailed: 2
        default: 64
        }
    }

    var suppressTextOutput: Bool {
        if case .diagnosticsFailed(_, let jsonWasPrinted) = self { return jsonWasPrinted }
        return false
    }
}
