import Darwin
import Foundation
import SparkleReleaseKitCLISupport
import SparkleReleaseKitCore

struct SparkleKitCLI {
    static let version = "0.3.0"

    private let configurationStore = ConfigurationStore()
    private let terminalIO: TerminalIO

    init(terminalIO: TerminalIO = .standard()) {
        self.terminalIO = terminalIO
    }

    func run(arguments: [String]) throws {
        let command = arguments.first ?? "help"
        let rest = Array(arguments.dropFirst())

        switch command {
        case "quickstart": try setup(rest, command: "quickstart")
        case "setup": try setup(rest, command: "setup")
        case "doctor": try doctor(rest)
        case "integrate": try integrate(rest)
        case "test": try test(rest)
        case "verify": try verify(rest)
        case "verify-update": try verifyUpdate(rest)
        case "validate-feed": try validateFeed(rest)
        case "prepare-release": try prepareRelease(rest)
        case "publish": try publish(rest)
        case "explain": try explain(rest)
        case "version", "--version", "-v":
            guard rest.isEmpty else { throw CLIError.unexpectedArgument(rest[0]) }
            print("SparkleReleaseKit \(Self.version) (Sparkle \(SparkleKitConfiguration.supportedSparkleVersion))")
        case "help", "--help", "-h":
            guard rest.isEmpty else { throw CLIError.unexpectedArgument(rest[0]) }
            printHelp()
        default: throw CLIError.unknownCommand(command)
        }
    }

    private func setup(_ arguments: [String], command: String) throws {
        let options = try Options(
            arguments,
            valueOptions: [
                "owner", "repo", "app-name", "bundle-id", "container", "target", "scheme",
                "feed-url", "public-key", "release-mode", "architectures", "team-id", "template",
            ],
            booleanFlags: [
                "apply", "json", "require-sparkle-signature", "require-developer-id",
                "require-notarization", "allow-ad-hoc-signing", "interactive", "non-interactive",
                "with-workflow", "open-xcode", "allow-project-execution", "allow-network",
            ]
        )
        try options.rejectExtraPositionals(maximum: 1)
        guard !(options.flag("interactive") && options.flag("non-interactive")) else {
            throw CLIError.conflictingOptions("--interactive and --non-interactive")
        }
        let root = URL(fileURLWithPath: options.positionals.first ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        let json = options.flag("json")
        let terminalIsInteractive = terminalIO.stdinIsTTY
        if options.flag("interactive"), !terminalIsInteractive {
            throw CLIError.nonInteractiveValueRequired("an interactive terminal")
        }
        let interactive =
            !json && !options.flag("non-interactive")
            && (options.flag("interactive") || terminalIsInteractive)
        if command == "quickstart", interactive {
            try guidedQuickstart(root: root, options: options)
            return
        }
        if !json {
            header(command == "quickstart" ? "Guided Sparkle setup" : "Set up secure Sparkle updates")
            info("Inspecting \(root.path)")
            if !options.flag("allow-project-execution") {
                info("Passive inspection only; xcodebuild will not run.")
            }
        }

        let detected = try ProjectDetector().detect(
            at: root,
            options: .init(
                allowProjectExecution: options.flag("allow-project-execution"),
                container: options.value("container"),
                scheme: options.value("scheme"),
                target: options.value("target")
            )
        )
        let owner = try resolvedValue(
            options.value("owner") ?? detected.githubOwner,
            label: "GitHub owner",
            defaultValue: detected.githubOwner,
            interactive: interactive
        )
        let repository = try resolvedValue(
            options.value("repo") ?? detected.githubRepository,
            label: "GitHub repository",
            defaultValue: detected.githubRepository ?? detected.rootURL.lastPathComponent,
            interactive: interactive
        )
        let appName = interactive
            ? prompt("Application name", defaultValue: options.value("app-name") ?? detected.appName)
            : options.value("app-name") ?? detected.appName
        let bundleID = interactive
            ? prompt("Bundle identifier", defaultValue: options.value("bundle-id") ?? detected.bundleIdentifier)
            : options.value("bundle-id") ?? detected.bundleIdentifier
        let target = interactive
            ? prompt("Application target", defaultValue: options.value("target") ?? detected.targetName)
            : options.value("target") ?? detected.targetName
        let scheme = interactive
            ? prompt("Shared scheme", defaultValue: options.value("scheme") ?? detected.scheme)
            : options.value("scheme") ?? detected.scheme
        let modeValue = interactive
            ? prompt("Release mode (free, developer-id, auto)", defaultValue: options.value("release-mode") ?? "free")
            : options.value("release-mode")
        let templateValue = interactive
            ? prompt("Template (auto, minimal, swiftui, appkit)", defaultValue: options.value("template") ?? "auto")
            : options.value("template")
        let publicKey = interactive
            ? prompt("Public Sparkle EdDSA key (optional for the first pass)", defaultValue: options.value("public-key") ?? "")
            : options.value("public-key") ?? ""
        let feedURL =
            options.value("feed-url")
            ?? "https://\(owner.lowercased()).github.io/\(repository)/appcast.xml"
        let container = relativePath(detected.containerURL, to: detected.rootURL)
        let infoPlist = detected.infoPlistURL.map { relativePath($0, to: detected.rootURL) }
        let releaseMode = try parsedReleaseMode(modeValue) ?? .free
        let template = try parsedTemplate(templateValue)
        let architectures = try parsedArchitectures(options.value("architectures")) ?? [.arm64, .x86_64]
        let includeWorkflow =
            command == "setup"
            || options.flag("with-workflow")
            || (interactive && promptBoolean("Generate a GitHub validation workflow?", defaultValue: true))
        let distribution = SparkleKitConfiguration.Distribution(
            releaseMode: releaseMode,
            requireSparkleSignature: true,
            requireDeveloperID: options.flag("require-developer-id") ? true : nil,
            requireNotarization: options.flag("require-notarization") ? true : nil,
            allowAdHocSigning: options.flag("allow-ad-hoc-signing") ? true : nil,
            expectedArchitectures: architectures,
            expectedTeamIdentifier: options.value("team-id")
        )

        let configuration = SparkleKitConfiguration(
            app: .init(
                name: appName,
                bundleIdentifier: bundleID,
                minimumMacOS: detected.minimumMacOS,
                style: detected.style,
                sandboxed: detected.sandboxed
            ),
            project: .init(
                container: container,
                target: target,
                scheme: scheme,
                infoPlist: infoPlist,
                template: template,
                generateWorkflow: includeWorkflow
            ),
            github: .init(owner: owner, repository: repository),
            updates: .init(feedURL: feedURL, publicEDKey: publicKey),
            distribution: distribution
        )
        let configURL = detected.rootURL.appendingPathComponent(ConfigurationStore.defaultFileName)
        let integration = try Integrator().integrate(
            projectRoot: detected.rootURL,
            configuration: configuration,
            apply: options.flag("apply"),
            allowConfigurationOnly: true
        )
        if options.flag("open-xcode") {
            let opened = try ProcessRunner().run(
                "/usr/bin/open",
                arguments: ["-a", "Xcode", detected.containerURL.path],
                timeout: 30
            )
            guard opened.status == 0, !opened.timedOut else {
                throw CLIError.externalCommandFailed("Xcode could not be opened.")
            }
        }

        if json {
            try printEnvelope(
                command: command,
                success: true,
                changes: integration.changes,
                artifacts: integration.applied ? [.init(type: "configuration", path: configURL.path)] : [],
                metadata: SetupReport(
                    configurationPath: configURL,
                    configuration: configuration,
                    integration: integration
                )
            )
            return
        }

        printChanges(integration.changes)
        detail("App", configuration.app.name)
        detail("Target", target)
        detail("Scheme", configuration.project.scheme)
        detail("Target style", configuration.app.style.rawValue)
        detail("Sandbox", configuration.app.sandboxed.map { $0 ? "enabled" : "disabled" } ?? "not detected")
        detail("Xcode container", configuration.project.container)
        detail("Feed", configuration.updates.feedURL)
        detail("Release mode", configuration.distribution.releaseMode.rawValue)
        detail("Template", configuration.project.template.rawValue)

        if publicKey.isEmpty {
            warning("The public EdDSA key is still missing.")
            print(
                "\nRun Sparkle's official generate_keys tool once, then add only its printed public key to updates.publicEDKey in sparklekit.json."
            )
            if integration.applied {
                success("The configuration draft was written; updater files were intentionally deferred.")
            } else {
                print("\nNo files were changed. Apply the configuration draft with: sparklekit \(command) \(shellQuoted(root.path)) --apply")
            }
            print("After adding the public key, run: sparklekit doctor \(shellQuoted(detected.rootURL.path)) --fix")
        } else if integration.applied {
            success("The reviewed setup plan was applied.")
            print("Open SparkleReleaseKit/INTEGRATION.md and complete the two explicit Xcode steps.")
        } else {
            print("\nNo files were changed. Apply this exact plan with: sparklekit \(command) \(shellQuoted(root.path)) --apply")
        }

        if options.flag("open-xcode") {
            info("Opened \(detected.containerURL.lastPathComponent) in Xcode.")
        }
    }

    private func guidedQuickstart(root: URL, options: Options) throws {
        let terminal = GuidedTerminal(io: terminalIO)
        let progress = TerminalProgressReporter(io: terminalIO)
        let totalSteps = 7

        terminalIO.writeLine()
        terminalIO.writeLine("SparkleReleaseKit")
        terminalIO.writeLine("Guided Sparkle setup")
        terminalIO.writeLine()
        terminalIO.writeLine("Nothing will be written until you review the plan and approve it.")
        terminalIO.writeLine("Private signing keys are never requested or printed.")
        terminalIO.writeLine()

        var detectionOptions = ProjectDetectionOptions(
            allowProjectExecution: options.flag("allow-project-execution"),
            container: options.value("container"),
            scheme: options.value("scheme"),
            target: options.value("target")
        )
        let inspection = progress.begin(
            step: 1,
            total: totalSteps,
            title: "Inspecting Xcode project"
        )
        if detectionOptions.allowProjectExecution {
            progress.detail("xcodebuild-backed inspection was explicitly permitted.")
        } else {
            progress.detail("Passive inspection only; target-project code will not run.")
            if terminal.confirm(
                "      Allow xcodebuild-backed inspection for more metadata?",
                defaultValue: false
            ) {
                detectionOptions.allowProjectExecution = true
                progress.detail("Project execution approved for inspection only.")
            }
        }

        let detected: DetectedProject
        do {
            guard let result = try guidedProjectDetection(
                at: root,
                options: &detectionOptions,
                terminal: terminal,
                progress: progress
            ) else {
                progress.skipped(
                    inspection,
                    reason: "Cancelled before approval; no files were changed."
                )
                terminalIO.writeLine("No files were changed.")
                return
            }
            detected = result
            progress.detail("Found \(detected.containerURL.lastPathComponent)")
            progress.complete(inspection)
        } catch {
            progress.fail(inspection, error: error)
            throw error
        }

        var draft = GuidedSetupDraft(
            owner: options.value("owner") ?? detected.githubOwner,
            repository: options.value("repo")
                ?? detected.githubRepository
                ?? detected.rootURL.lastPathComponent,
            appName: options.value("app-name") ?? detected.appName,
            bundleIdentifier: options.value("bundle-id") ?? detected.bundleIdentifier,
            target: detectionOptions.target ?? detected.targetName,
            scheme: detectionOptions.scheme ?? detected.scheme,
            releaseMode: try parsedReleaseMode(options.value("release-mode")) ?? .free,
            template: try parsedTemplate(options.value("template")),
            architectures: try parsedArchitectures(options.value("architectures"))
                ?? [.arm64, .x86_64],
            generateWorkflow: options.flag("with-workflow")
        )

        let review = progress.begin(
            step: 2,
            total: totalSteps,
            title: "Reviewing detected application"
        )
        reviewLoop: while true {
            progress.detail("Container: \(relativePath(detected.containerURL, to: detected.rootURL))")
            progress.detail("Target: \(draft.target)")
            progress.detail("Scheme: \(draft.scheme)")
            progress.detail("Style: \(displayName(detected.style))")
            progress.detail(
                "Sandbox: \(detected.sandboxed.map { $0 ? "Enabled" : "Disabled" } ?? "Not detected")"
            )
            progress.detail("Release mode: \(displayName(draft.releaseMode))")
            progress.detail("Template: \(displayName(draft.template))")
            if let owner = draft.owner {
                progress.detail("GitHub: \(owner)/\(draft.repository)")
            } else {
                progress.detail("GitHub owner: Not detected; required in the next step.")
            }

            switch terminal.reviewDecision() {
            case .use:
                progress.complete(review, message: "Selection accepted")
                break reviewLoop
            case .edit:
                draft.appName = terminal.prompt(
                    "      Application name",
                    defaultValue: draft.appName
                )
                draft.bundleIdentifier = terminal.prompt(
                    "      Bundle identifier",
                    defaultValue: draft.bundleIdentifier
                )
                draft.target = terminal.prompt(
                    "      Application target",
                    defaultValue: draft.target
                )
                draft.scheme = terminal.prompt(
                    "      Shared scheme",
                    defaultValue: draft.scheme
                )
                let owner = terminal.prompt(
                    "      GitHub owner",
                    defaultValue: draft.owner ?? ""
                )
                draft.owner = owner.isEmpty ? nil : owner
                draft.repository = terminal.prompt(
                    "      GitHub repository",
                    defaultValue: draft.repository
                )
                draft.releaseMode = try parsedReleaseMode(
                    terminal.prompt(
                        "      Release mode (free, developer-id, auto)",
                        defaultValue: draft.releaseMode.rawValue
                    )
                ) ?? .free
                draft.template = try parsedTemplate(
                    terminal.prompt(
                        "      Template (auto, minimal, swiftui, appkit)",
                        defaultValue: draft.template.rawValue
                    )
                )
                progress.detail("Selection updated. Review the complete result again.")
            case .cancel:
                progress.skipped(
                    review,
                    reason: "Cancelled before approval; no files were changed."
                )
                terminalIO.writeLine("No files were changed.")
                return
            }
        }

        let configurationStep = progress.begin(
            step: 3,
            total: totalSteps,
            title: "Preparing Sparkle configuration"
        )
        let owner = try guidedRequiredValue(
            draft.owner,
            label: "      GitHub owner",
            terminal: terminal
        )
        let repository = try guidedRequiredValue(
            draft.repository,
            label: "      GitHub repository",
            terminal: terminal
        )
        let defaultFeed =
            options.value("feed-url")
            ?? "https://\(owner.lowercased()).github.io/\(repository)/appcast.xml"
        let feedURL = options.value("feed-url")
            ?? terminal.prompt("      Update feed URL", defaultValue: defaultFeed)
        let publicKey = options.value("public-key")
            ?? terminal.prompt(
                "      Public Sparkle EdDSA key (optional; Return defers it)",
                showDefault: false
            )
        if !draft.generateWorkflow {
            draft.generateWorkflow = terminal.confirm(
                "      Generate a GitHub validation workflow?",
                defaultValue: true
            )
        }

        let configuration = SparkleKitConfiguration(
            app: .init(
                name: draft.appName,
                bundleIdentifier: draft.bundleIdentifier,
                minimumMacOS: detected.minimumMacOS,
                style: detected.style,
                sandboxed: detected.sandboxed
            ),
            project: .init(
                container: relativePath(detected.containerURL, to: detected.rootURL),
                target: draft.target,
                scheme: draft.scheme,
                infoPlist: detected.infoPlistURL.map {
                    relativePath($0, to: detected.rootURL)
                },
                template: draft.template,
                generateWorkflow: draft.generateWorkflow
            ),
            github: .init(owner: owner, repository: repository),
            updates: .init(feedURL: feedURL, publicEDKey: publicKey),
            distribution: .init(
                releaseMode: draft.releaseMode,
                requireSparkleSignature: true,
                requireDeveloperID: options.flag("require-developer-id") ? true : nil,
                requireNotarization: options.flag("require-notarization") ? true : nil,
                allowAdHocSigning: options.flag("allow-ad-hoc-signing") ? true : nil,
                expectedArchitectures: draft.architectures,
                expectedTeamIdentifier: options.value("team-id")
            )
        )
        progress.detail("Release mode: \(displayName(configuration.distribution.releaseMode))")
        progress.detail("Feed: \(configuration.updates.feedURL)")
        progress.detail(
            "Update key: \(publicKey.isEmpty ? "Deferred; updater files will wait" : "Public key provided")"
        )
        progress.complete(configurationStep)

        let planStep = progress.begin(
            step: 4,
            total: totalSteps,
            title: "Reviewing planned changes"
        )
        let preview: IntegrationResult
        do {
            preview = try progress.withHeartbeat(operation: "Building transactional plan") {
                try Integrator().integrate(
                    projectRoot: detected.rootURL,
                    configuration: configuration,
                    apply: false,
                    allowConfigurationOnly: true
                )
            }
        } catch {
            progress.fail(planStep, error: error)
            throw error
        }
        let counts = changeCounts(preview.changes)
        progress.detail("\(counts.created) file(s) will be created")
        progress.detail("\(counts.updated) file(s) will be updated")
        progress.detail("\(counts.unchanged) file(s) are already correct")
        if terminal.confirm("      Show detailed changes?", defaultValue: true) {
            for change in preview.changes {
                progress.detail(
                    "\(changeMarker(change.kind)) \(change.relativePath): \(change.summary)"
                )
            }
        }
        let hasChanges = counts.created + counts.updated > 0
        let applyApproved =
            hasChanges
            && terminal.confirm("      Apply these changes?", defaultValue: false)
        progress.complete(
            planStep,
            message: applyApproved ? "Plan reviewed and approved" : "Plan reviewed"
        )

        var integration = preview
        let applyStep = progress.begin(
            step: 5,
            total: totalSteps,
            title: applyApproved ? "Applying integration" : "Applying integration"
        )
        if applyApproved {
            do {
                integration = try progress.withHeartbeat(
                    operation: "Writing files transactionally"
                ) {
                    try Integrator().integrate(
                        projectRoot: detected.rootURL,
                        configuration: configuration,
                        apply: true,
                        allowConfigurationOnly: true
                    )
                }
                if let backup = integration.backupURL {
                    progress.detail("Backup created: \(backup.path)")
                }
                progress.detail(
                    integration.applied
                        ? "Files written successfully."
                        : "No rewrite was needed; every managed file was already correct."
                )
                if options.flag("open-xcode") {
                    try openXcode(detected.containerURL, progress: progress)
                }
                progress.complete(applyStep)
            } catch {
                progress.fail(applyStep, error: error)
                throw error
            }
        } else if options.flag("open-xcode") {
            do {
                try openXcode(detected.containerURL, progress: progress)
                progress.detail("Project files remain unchanged.")
                progress.complete(applyStep, message: "Xcode opened")
            } catch {
                progress.fail(applyStep, error: error)
                throw error
            }
        } else {
            progress.skipped(
                applyStep,
                reason: hasChanges
                    ? "Approval was not given; no files were changed."
                    : "Every managed file is already correct."
            )
        }

        let doctorStep = progress.begin(
            step: 6,
            total: totalSteps,
            title: "Checking integration"
        )
        let diagnostics = try progress.withHeartbeat(operation: "Running passive doctor checks") {
            Doctor().inspect(
                projectRoot: detected.rootURL,
                configuration: configuration
            )
        }
        for diagnostic in diagnostics.prefix(12) {
            let status =
                switch diagnostic.severity {
                case .pass: "PASS"
                case .warning: "WARNING"
                case .failure: "ACTION REQUIRED"
                }
            progress.detail("\(diagnostic.title): \(status) [\(diagnostic.id)]")
        }
        let doctorFailures = diagnostics.filter { $0.severity == .failure }
        let doctorWarnings = diagnostics.filter { $0.severity == .warning }
        if !doctorFailures.isEmpty {
            progress.warn(
                doctorStep,
                message: "\(doctorFailures.count) check(s) still require action."
            )
        } else if !doctorWarnings.isEmpty {
            progress.warn(
                doctorStep,
                message: "\(doctorWarnings.count) warning(s) still require review."
            )
        } else {
            progress.complete(doctorStep)
        }

        let summary = progress.begin(
            step: 7,
            total: totalSteps,
            title: "Setup ready"
        )
        progress.detail(
            "Files changed: \(integration.applied ? "Yes" : "No")"
        )
        if let backup = integration.backupURL {
            progress.detail("Backup: \(backup.path)")
        }
        progress.detail(
            "Project execution: \(detectionOptions.allowProjectExecution ? "Allowed for inspection" : "Not allowed")"
        )
        progress.detail("Network access: Not used")
        progress.complete(summary, message: "Guided setup finished")

        terminalIO.writeLine("Next required steps:")
        var nextStep = 1
        if !integration.applied, hasChanges {
            terminalIO.writeLine(
                "\(nextStep). Run sparklekit quickstart \(shellQuoted(root.path)) again and approve the reviewed plan."
            )
            nextStep += 1
        }
        if publicKey.isEmpty {
            terminalIO.writeLine(
                "\(nextStep). Generate a Sparkle EdDSA key and add only its public key to sparklekit.json."
            )
            nextStep += 1
        }
        terminalIO.writeLine(
            "\(nextStep). Add the official Sparkle package to target \(TerminalSanitizer.text(draft.target, preserveNewlines: false)) in Xcode."
        )
        nextStep += 1
        terminalIO.writeLine(
            "\(nextStep). Connect AppUpdater to the \(displayName(detected.style)) application lifecycle."
        )
        nextStep += 1
        terminalIO.writeLine(
            "\(nextStep). Run sparklekit doctor \(shellQuoted(detected.rootURL.path)) after the Xcode steps."
        )
        terminalIO.writeLine()
        terminalIO.writeLine(
            "A real update, signature, appcast, or release build was not verified by quickstart."
        )
    }

    private func guidedProjectDetection(
        at root: URL,
        options: inout ProjectDetectionOptions,
        terminal: GuidedTerminal,
        progress: TerminalProgressReporter
    ) throws -> DetectedProject? {
        for _ in 0..<8 {
            do {
                return try progress.withHeartbeat(
                    operation: options.allowProjectExecution
                        ? "Inspecting project with xcodebuild permission"
                        : "Inspecting project metadata passively"
                ) {
                    try ProjectDetector().detect(at: root, options: options)
                }
            } catch ProjectDetectionError.ambiguousContainers(let choices) {
                progress.detail("Multiple Xcode containers were found.")
                guard let selected = terminal.chooseNumbered(
                    "Choose the Xcode container",
                    choices: choices
                ) else { return nil }
                options.container = selected
            } catch ProjectDetectionError.ambiguousApplicationTargets(let choices) {
                progress.detail("Multiple application targets were found.")
                guard let selected = terminal.chooseNumbered(
                    "Choose the application target",
                    choices: choices
                ) else { return nil }
                options.target = selected
            } catch ProjectDetectionError.ambiguousSchemes(let choices) {
                progress.detail("Multiple shared schemes were found.")
                guard let selected = terminal.chooseNumbered(
                    "Choose the shared scheme",
                    choices: choices
                ) else { return nil }
                options.scheme = selected
            }
        }
        throw CLIError.externalCommandFailed(
            "Project selection did not converge after resolving repeated ambiguities."
        )
    }

    private func guidedRequiredValue(
        _ initialValue: String?,
        label: String,
        terminal: GuidedTerminal
    ) throws -> String {
        var value = initialValue ?? ""
        while value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = terminal.prompt(label)
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                terminalIO.writeLine("      This value is required to create a deterministic configuration.")
            }
        }
        return value
    }

    private func openXcode(
        _ containerURL: URL,
        progress: TerminalProgressReporter
    ) throws {
        let opened = try progress.withHeartbeat(operation: "Opening Xcode") {
            try ProcessRunner().run(
                "/usr/bin/open",
                arguments: ["-a", "Xcode", containerURL.path],
                timeout: 30
            )
        }
        guard opened.status == 0, !opened.timedOut else {
            throw CLIError.externalCommandFailed("Xcode could not be opened.")
        }
        progress.detail("Opened \(containerURL.lastPathComponent) in Xcode.")
    }

    private func changeCounts(
        _ changes: [IntegrationChange]
    ) -> (created: Int, updated: Int, unchanged: Int) {
        (
            changes.filter { $0.kind == .create }.count,
            changes.filter { $0.kind == .update }.count,
            changes.filter { $0.kind == .unchanged }.count
        )
    }

    private func changeMarker(_ kind: IntegrationChange.Kind) -> String {
        switch kind {
        case .create: "+"
        case .update: "~"
        case .unchanged: "="
        }
    }

    private func displayName(_ value: AppStyle) -> String {
        switch value {
        case .swiftUI: "SwiftUI"
        case .appKit: "AppKit"
        case .unknown: "Unknown"
        }
    }

    private func displayName(_ value: ReleaseMode) -> String {
        switch value {
        case .free: "Free"
        case .developerID: "Developer ID"
        case .auto: "Auto"
        }
    }

    private func displayName(_ value: IntegrationTemplate) -> String {
        switch value {
        case .auto: "Auto"
        case .minimal: "Minimal"
        case .swiftUI: "SwiftUI"
        case .appKit: "AppKit"
        }
    }

    private func doctor(_ arguments: [String]) throws {
        let options = try Options(arguments, booleanFlags: ["json", "fix", "apply"])
        try options.rejectExtraPositionals(maximum: 1)
        guard !options.flag("apply") || options.flag("fix") else {
            throw CLIError.conflictingOptions("--apply requires --fix")
        }
        let root = projectRoot(options)
        let json = options.flag("json")
        let progress = json ? nil : TerminalProgressReporter(io: terminalIO)
        if !json {
            header("SparkleReleaseKit doctor")
        }
        let loaded = loadConfigurationForDiagnostics(root)
        var diagnostics: [Diagnostic]
        if let progress {
            let token = progress.begin(
                step: 1,
                total: options.flag("fix") ? 2 : 1,
                title: "Running passive doctor checks"
            )
            diagnostics = try progress.withHeartbeat(operation: "Inspecting integration state") {
                Doctor().inspect(
                    projectRoot: root,
                    configuration: loaded.configuration,
                    configurationError: loaded.error
                )
            }
            let initialFailures = diagnostics.filter { $0.severity == .failure }.count
            let initialWarnings = diagnostics.filter { $0.severity == .warning }.count
            if initialFailures > 0 {
                progress.warn(
                    token,
                    message: "\(initialFailures) check(s) require action."
                )
            } else if initialWarnings > 0 {
                progress.warn(
                    token,
                    message: "\(initialWarnings) warning(s) to review."
                )
            } else {
                progress.complete(token)
            }
        } else {
            diagnostics = Doctor().inspect(
                projectRoot: root,
                configuration: loaded.configuration,
                configurationError: loaded.error
            )
        }
        var fixResult: IntegrationResult?
        if options.flag("fix"), let configuration = loaded.configuration {
            if let progress {
                let token = progress.begin(
                    step: 2,
                    total: 2,
                    title: options.flag("apply")
                        ? "Applying deterministic repairs"
                        : "Previewing deterministic repairs"
                )
                do {
                    fixResult = try progress.withHeartbeat(
                        operation: options.flag("apply")
                            ? "Writing repairs transactionally"
                            : "Building repair plan"
                    ) {
                        try Integrator().integrate(
                            projectRoot: root,
                            configuration: configuration,
                            apply: options.flag("apply"),
                            allowConfigurationOnly: true
                        )
                    }
                    if options.flag("apply") {
                        diagnostics = Doctor().inspect(
                            projectRoot: root,
                            configuration: configuration
                        )
                    }
                    progress.complete(
                        token,
                        message: options.flag("apply")
                            ? "Repair transaction completed"
                            : "Repair preview completed"
                    )
                } catch {
                    progress.fail(token, error: error)
                    throw error
                }
            } else {
                fixResult = try Integrator().integrate(
                    projectRoot: root,
                    configuration: configuration,
                    apply: options.flag("apply"),
                    allowConfigurationOnly: true
                )
                if options.flag("apply") {
                    diagnostics = Doctor().inspect(
                        projectRoot: root,
                        configuration: configuration
                    )
                }
            }
        } else if options.flag("fix"), let progress {
            let token = progress.begin(
                step: 2,
                total: 2,
                title: "Previewing deterministic repairs"
            )
            progress.skipped(
                token,
                reason: "A valid configuration is required before repairs can be planned."
            )
        }
        let failures = diagnostics.filter {
            $0.severity == .failure
                && (!options.flag("fix") || options.flag("apply") || !$0.automaticFixAvailable)
        }

        if json {
            try printEnvelope(
                command: "doctor",
                success: failures.isEmpty,
                diagnostics: diagnostics,
                changes: fixResult?.changes ?? [],
                artifacts: fixResult?.backupURL.map { [.init(type: "backup", path: $0.path)] } ?? [],
                metadata: DoctorReport(
                    fixRequested: options.flag("fix"),
                    applied: fixResult?.applied ?? false
                )
            )
        } else {
            printDiagnostics(diagnostics)
            if let fixResult {
                print("\nRepair plan")
                printChanges(fixResult.changes)
                if fixResult.applied {
                    success("Safe deterministic fixes were applied.")
                    if let backup = fixResult.backupURL { info("Backup: \(backup.path)") }
                } else {
                    print("\nNo repair files were changed. Apply the plan with: sparklekit doctor \(shellQuoted(root.path)) --fix --apply")
                }
            }
            print("\n\(diagnostics.count - failures.count) checks passed or need attention; \(failures.count) failed.")
        }
        diagnostics.removeAll(keepingCapacity: false)
        if !failures.isEmpty { throw CLIError.diagnosticsFailed(failures.count, jsonWasPrinted: json) }
    }

    private func integrate(_ arguments: [String]) throws {
        let options = try Options(arguments, booleanFlags: ["apply", "json"])
        try options.rejectExtraPositionals(maximum: 1)
        let root = projectRoot(options)
        let configuration = try configurationStore.load(from: root.appendingPathComponent(ConfigurationStore.defaultFileName))
        let result = try Integrator().integrate(projectRoot: root, configuration: configuration, apply: options.flag("apply"))

        if options.flag("json") {
            try printEnvelope(
                command: "integrate",
                success: true,
                changes: result.changes,
                artifacts: result.backupURL.map { [.init(type: "backup", path: $0.path)] } ?? [],
                metadata: result
            )
            return
        }
        header(result.applied ? "Apply Sparkle integration" : "Preview Sparkle integration")
        printChanges(result.changes)
        if result.applied {
            success("Integration files were written successfully.")
            if let backup = result.backupURL { info("Backup: \(backup.path)") }
            print("\nOpen SparkleReleaseKit/INTEGRATION.md, complete the two Xcode steps, then run sparklekit doctor.")
        } else if result.changes.contains(where: { $0.kind != .unchanged }) {
            print("\nNo files were changed. Apply this plan with: sparklekit integrate \(shellQuoted(root.path)) --apply")
        } else {
            success("The integration is already up to date; no backup or rewrite was needed.")
        }
    }

    private func test(_ arguments: [String]) throws {
        let options = try Options(
            arguments,
            booleanFlags: ["json", "allow-project-execution", "allow-network"]
        )
        try options.rejectExtraPositionals(maximum: 1)
        guard options.flag("allow-project-execution") else {
            throw CLIError.permissionRequired(
                "test may execute Xcode build scripts and package plug-ins; pass --allow-project-execution"
            )
        }
        let root = projectRoot(options)
        let configuration = try configurationStore.load(from: root.appendingPathComponent(ConfigurationStore.defaultFileName))
        let json = options.flag("json")
        var diagnostics: [Diagnostic]
        if json {
            diagnostics = Doctor().inspect(projectRoot: root, configuration: configuration)
            if !diagnostics.contains(where: { $0.severity == .failure }) {
                diagnostics += try XcodeBuildValidator().validate(
                    projectRoot: root,
                    configuration: configuration,
                    allowNetwork: options.flag("allow-network")
                )
            }
        } else {
            header("Test the complete integration")
            let progress = TerminalProgressReporter(io: terminalIO)
            let doctorStep = progress.begin(
                step: 1,
                total: 2,
                title: "Running passive prerequisite checks"
            )
            diagnostics = try progress.withHeartbeat(operation: "Inspecting integration state") {
                Doctor().inspect(projectRoot: root, configuration: configuration)
            }
            let prerequisiteFailures = diagnostics.filter { $0.severity == .failure }.count
            let prerequisiteWarnings = diagnostics.filter { $0.severity == .warning }.count
            if prerequisiteFailures > 0 {
                progress.warn(
                    doctorStep,
                    message: "\(prerequisiteFailures) prerequisite check(s) require action."
                )
            } else if prerequisiteWarnings > 0 {
                progress.warn(
                    doctorStep,
                    message: "\(prerequisiteWarnings) prerequisite warning(s) to review."
                )
            } else {
                progress.complete(doctorStep)
            }

            let buildStep = progress.begin(
                step: 2,
                total: 2,
                title: "Running Xcode Release validation"
            )
            if prerequisiteFailures > 0 {
                progress.skipped(
                    buildStep,
                    reason: "Resolve prerequisite failures before running target-project code."
                )
            } else {
                do {
                    let buildDiagnostics = try progress.withHeartbeat(
                        operation: options.flag("allow-network")
                            ? "Running xcodebuild with automatic package resolution"
                            : "Running xcodebuild with package resolution disabled"
                    ) {
                        try XcodeBuildValidator().validate(
                            projectRoot: root,
                            configuration: configuration,
                            allowNetwork: options.flag("allow-network")
                        )
                    }
                    diagnostics += buildDiagnostics
                    let buildFailures = buildDiagnostics.filter {
                        $0.severity == .failure
                    }.count
                    let buildWarnings = buildDiagnostics.filter {
                        $0.severity == .warning
                    }.count
                    if buildFailures > 0 {
                        progress.fail(
                            buildStep,
                            message: "\(buildFailures) Xcode validation check(s) failed."
                        )
                    } else if buildWarnings > 0 {
                        progress.warn(
                            buildStep,
                            message: "\(buildWarnings) Xcode validation warning(s) to review."
                        )
                    } else {
                        progress.complete(buildStep)
                    }
                } catch {
                    progress.fail(buildStep, error: error)
                    throw error
                }
            }
        }
        let failures = diagnostics.filter { $0.severity == .failure }
        if json {
            try printEnvelope(
                command: "test",
                success: failures.isEmpty,
                diagnostics: diagnostics,
                metadata: TestReport(
                    projectExecutionAllowed: true,
                    networkAllowed: options.flag("allow-network")
                )
            )
        } else {
            printDiagnostics(diagnostics)
        }
        if !failures.isEmpty { throw CLIError.diagnosticsFailed(failures.count, jsonWasPrinted: json) }
    }

    private func verify(_ arguments: [String]) throws {
        let options = try Options(
            arguments,
            valueOptions: ["project", "release-mode"],
            booleanFlags: [
                "json", "require-developer-id", "require-notarization",
                "allow-ad-hoc-signing", "allow-unsigned",
            ]
        )
        try options.rejectExtraPositionals(maximum: 1)
        guard let archivePath = options.positionals.first else { throw CLIError.missingArgument("archive path") }
        let root = URL(fileURLWithPath: options.value("project") ?? FileManager.default.currentDirectoryPath).standardizedFileURL
        let configurationURL = root.appendingPathComponent(ConfigurationStore.defaultFileName)
        let configuration =
            FileManager.default.fileExists(atPath: configurationURL.path)
            ? try configurationStore.load(from: configurationURL)
            : nil
        let distribution =
            configuration?.distribution
            ?? .init(expectedArchitectures: [])
        let policy = try ReleaseVerificationPolicy(
            distribution: distribution,
            overrides: try policyOverrides(from: options)
        )
        let json = options.flag("json")
        let result: ReleaseInspectionResult
        if json {
            result = try ReleaseVerifier().inspect(
                archiveURL: URL(fileURLWithPath: archivePath),
                expectedBundleIdentifier: configuration?.app.bundleIdentifier,
                policy: policy
            )
        } else {
            header("Verify release archive")
            let progress = TerminalProgressReporter(io: terminalIO)
            let token = progress.begin(
                step: 1,
                total: 1,
                title: "Inspecting release archive"
            )
            do {
                result = try progress.withHeartbeat(
                    operation: "Checking archive, signatures, and policy"
                ) {
                    try ReleaseVerifier().inspect(
                        archiveURL: URL(fileURLWithPath: archivePath),
                        expectedBundleIdentifier: configuration?.app.bundleIdentifier,
                        policy: policy
                    )
                }
                let inspectionFailures = result.diagnostics.filter {
                    $0.severity == .failure
                }.count
                let inspectionWarnings = result.diagnostics.filter {
                    $0.severity == .warning
                }.count
                if inspectionFailures > 0 {
                    progress.fail(
                        token,
                        message: "\(inspectionFailures) release verification check(s) failed."
                    )
                } else if inspectionWarnings > 0 {
                    progress.warn(
                        token,
                        message: "\(inspectionWarnings) release verification warning(s) to review."
                    )
                } else {
                    progress.complete(token)
                }
            } catch {
                progress.fail(token, error: error)
                throw error
            }
        }
        let failures = result.diagnostics.filter { $0.severity == .failure }
        if json {
            try printEnvelope(
                command: "verify",
                success: failures.isEmpty,
                diagnostics: result.diagnostics,
                artifacts: [.init(type: "archive", path: URL(fileURLWithPath: archivePath).standardizedFileURL.path)],
                metadata: result
            )
        } else {
            printDiagnostics(result.diagnostics)
        }
        if !failures.isEmpty { throw CLIError.diagnosticsFailed(failures.count, jsonWasPrinted: json) }
    }

    private func verifyUpdate(_ arguments: [String]) throws {
        let options = try Options(
            arguments,
            valueOptions: ["appcast", "public-key", "version", "project"],
            booleanFlags: ["json"]
        )
        try options.rejectExtraPositionals(maximum: 1)
        guard let archivePath = options.positionals.first else { throw CLIError.missingArgument("archive path") }
        guard let appcastPath = options.value("appcast") else { throw CLIError.missingArgument("--appcast") }
        guard let version = options.value("version") else { throw CLIError.missingArgument("--version build number") }

        let root = URL(fileURLWithPath: options.value("project") ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        let configurationURL = root.appendingPathComponent(ConfigurationStore.defaultFileName)
        let configuration =
            FileManager.default.fileExists(atPath: configurationURL.path)
            ? try configurationStore.load(from: configurationURL)
            : nil
        guard let publicKey = options.value("public-key") ?? configuration?.updates.publicEDKey,
            !publicKey.isEmpty
        else {
            throw CLIError.missingArgument("--public-key or updates.publicEDKey in sparklekit.json")
        }

        let appcast = try AppcastValidator().validate(fileURL: URL(fileURLWithPath: appcastPath))
        let structuralFailures = appcast.diagnostics.filter { $0.severity == .failure }
        guard structuralFailures.isEmpty else {
            if options.flag("json") {
                try printEnvelope(
                    command: "verify-update",
                    success: false,
                    diagnostics: appcast.diagnostics,
                    metadata: appcast
                )
            }
            throw CLIError.diagnosticsFailed(structuralFailures.count, jsonWasPrinted: options.flag("json"))
        }
        let diagnostic = try UpdateSignatureVerifier().verify(
            archiveURL: URL(fileURLWithPath: archivePath),
            appcast: appcast,
            publicEDKey: publicKey,
            expectedBuildVersion: version
        )
        let diagnostics = appcast.diagnostics + [diagnostic]
        if options.flag("json") {
            try printEnvelope(
                command: "verify-update",
                success: true,
                diagnostics: diagnostics,
                artifacts: [
                    .init(type: "archive", path: URL(fileURLWithPath: archivePath).standardizedFileURL.path),
                    .init(type: "appcast", path: URL(fileURLWithPath: appcastPath).standardizedFileURL.path),
                ],
                metadata: VerifyUpdateReport(expectedBuildVersion: version)
            )
        } else {
            header("Verify Sparkle update signature")
            printDiagnostics(diagnostics)
        }
    }

    private func validateFeed(_ arguments: [String]) throws {
        let options = try Options(arguments, booleanFlags: ["json"])
        try options.rejectExtraPositionals(maximum: 1)
        guard let path = options.positionals.first else { throw CLIError.missingArgument("appcast.xml path") }
        let result = try AppcastValidator().validate(fileURL: URL(fileURLWithPath: path))
        let failures = result.diagnostics.filter { $0.severity == .failure }
        if options.flag("json") {
            try printEnvelope(
                command: "validate-feed",
                success: failures.isEmpty,
                diagnostics: result.diagnostics,
                artifacts: [.init(type: "appcast", path: URL(fileURLWithPath: path).standardizedFileURL.path)],
                metadata: result
            )
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
                "release-mode",
            ],
            booleanFlags: [
                "replace", "json", "require-sparkle-signature", "require-developer-id",
                "require-notarization", "allow-ad-hoc-signing", "allow-unsigned",
                "allow-project-execution",
            ]
        )
        try options.rejectExtraPositionals(maximum: 1)
        guard let archivePath = options.positionals.first else { throw CLIError.missingArgument("archive path") }
        guard let version = options.value("version") else { throw CLIError.missingArgument("--version") }
        let root = URL(fileURLWithPath: options.value("project") ?? FileManager.default.currentDirectoryPath).standardizedFileURL
        let configuration = try configurationStore.load(from: root.appendingPathComponent(ConfigurationStore.defaultFileName))
        let preparationOptions = ReleasePreparationOptions(
            version: version,
            archiveURL: URL(fileURLWithPath: archivePath),
            releaseNotesURL: options.value("notes").map(URL.init(fileURLWithPath:)),
            outputRootURL: options.value("output").map(URL.init(fileURLWithPath:)),
            generateAppcastURL: options.value("generate-appcast").map(URL.init(fileURLWithPath:)),
            keychainAccount: options.value("key-account") ?? "ed25519",
            downloadURLPrefix: options.value("download-url-prefix"),
            releaseNotesURLPrefix: options.value("release-notes-url-prefix"),
            phasedRolloutInterval: try options.integer("phased-rollout"),
            replaceExisting: options.flag("replace"),
            allowProjectExecution: options.flag("allow-project-execution"),
            policyOverrides: try policyOverrides(from: options)
        )
        let json = options.flag("json")
        let result: ReleasePreparationResult
        if json {
            result = try ReleasePreparer().prepare(
                projectRoot: root,
                configuration: configuration,
                options: preparationOptions
            )
        } else {
            header("Prepare signed Sparkle release")
            let progress = TerminalProgressReporter(io: terminalIO)
            let token = progress.begin(
                step: 1,
                total: 1,
                title: "Verifying and staging release"
            )
            do {
                result = try progress.withHeartbeat(
                    operation: "Inspecting archive and running generate_appcast"
                ) {
                    try ReleasePreparer().prepare(
                        projectRoot: root,
                        configuration: configuration,
                        options: preparationOptions
                    )
                }
                let warnings = result.diagnostics.filter {
                    $0.severity == .warning
                }.count
                if warnings > 0 {
                    progress.warn(
                        token,
                        message: "Release staged with \(warnings) warning(s) to review."
                    )
                } else {
                    progress.complete(token)
                }
            } catch {
                progress.fail(token, error: error)
                throw error
            }
        }
        if json {
            try printEnvelope(
                command: "prepare-release",
                success: true,
                diagnostics: result.diagnostics,
                artifacts: [
                    .init(type: "archive", path: result.archiveURL.path),
                    .init(type: "appcast", path: result.appcastURL.path),
                    .init(type: "checksum", path: result.checksumURL.path),
                    .init(type: "manifest", path: result.manifestURL.path),
                ],
                metadata: result
            )
        } else {
            printDiagnostics(result.diagnostics)
            success("Prepared \(result.metadata.appName) \(result.version)")
            detail("Stage", result.outputDirectory.path)
            detail("Archive", result.archiveURL.lastPathComponent)
            detail("Appcast", result.appcastURL.lastPathComponent)
            detail("SHA-256", result.checksumURL.lastPathComponent)
            detail("Manifest", result.manifestURL.lastPathComponent)
            print("\nReview this staging directory before uploading any asset or publishing a release.")
        }
    }

    private func publish(_ arguments: [String]) throws {
        guard arguments.first == "preview" else {
            if arguments.contains("--apply") {
                throw CLIError.permissionRequired(
                    "remote publishing is not implemented in v0.3; only 'publish preview' is available"
                )
            }
            throw CLIError.missingArgument("publish subcommand 'preview'")
        }
        let options = try Options(
            Array(arguments.dropFirst()),
            valueOptions: ["project"],
            booleanFlags: ["json"]
        )
        try options.rejectExtraPositionals(maximum: 1)
        let root = URL(
            fileURLWithPath: options.value("project") ?? FileManager.default.currentDirectoryPath
        ).standardizedFileURL
        let configuration = try configurationStore.load(
            from: root.appendingPathComponent(ConfigurationStore.defaultFileName)
        )
        let stage = try resolvedPublicationStage(
            options.positionals.first.map(URL.init(fileURLWithPath:)),
            projectRoot: root
        )
        let json = options.flag("json")
        let preview: PublicationPreview
        if json {
            preview = try PublicationPreviewer().preview(
                stageURL: stage,
                configuration: configuration
            )
        } else {
            header("Preview publication")
            let progress = TerminalProgressReporter(io: terminalIO)
            let token = progress.begin(
                step: 1,
                total: 1,
                title: "Building read-only publication preview"
            )
            do {
                preview = try progress.withHeartbeat(
                    operation: "Binding manifest, assets, and checksums"
                ) {
                    try PublicationPreviewer().preview(
                        stageURL: stage,
                        configuration: configuration
                    )
                }
                let previewFailures = preview.diagnostics.filter {
                    $0.severity == .failure
                }.count
                let previewWarnings = preview.diagnostics.filter {
                    $0.severity == .warning
                }.count
                if previewFailures > 0 {
                    progress.fail(
                        token,
                        message: "\(previewFailures) publication preview check(s) failed."
                    )
                } else if previewWarnings > 0 {
                    progress.warn(
                        token,
                        message: "\(previewWarnings) publication warning(s) to review."
                    )
                } else {
                    progress.complete(
                        token,
                        message: "Preview completed without network access"
                    )
                }
            } catch {
                progress.fail(token, error: error)
                throw error
            }
        }
        let failures = preview.diagnostics.filter { $0.severity == .failure }
        if json {
            try printEnvelope(
                command: "publish preview",
                success: failures.isEmpty,
                diagnostics: preview.diagnostics,
                artifacts: preview.assets.map {
                    .init(type: "publication-asset", path: stage.appendingPathComponent($0.name).path)
                },
                metadata: preview
            )
        } else {
            detail("Repository", preview.repository)
            detail("Tag", preview.tag)
            detail("Release mode", preview.releaseMode.rawValue)
            detail("Feed", preview.feedURL)
            print("\nAssets")
            for asset in preview.assets {
                print("  \(asset.name)  \(asset.bytes) bytes  \(asset.sha256)")
                if let url = asset.downloadURL { print("    \(url)") }
            }
            print("\nRequired permissions")
            preview.requiredPermissions.forEach { print("  \($0)") }
            print("\nPlanned remote writes")
            preview.plannedRemoteWrites.forEach { print("  \($0)") }
            printDiagnostics(preview.diagnostics)
            print("\nPreview only: no network request or remote write was performed.")
        }
        if !failures.isEmpty {
            throw CLIError.diagnosticsFailed(
                failures.count,
                jsonWasPrinted: json
            )
        }
    }

    private func explain(_ arguments: [String]) throws {
        let options = try Options(arguments, booleanFlags: ["json"])
        try options.rejectExtraPositionals(maximum: 1)
        guard let id = options.positionals.first else {
            throw CLIError.missingArgument("diagnostic ID")
        }
        guard let definition = DiagnosticCatalog.definition(for: id) else {
            throw CLIError.invalidDiagnosticID(id)
        }
        if options.flag("json") {
            try printEnvelope(
                command: "explain",
                success: true,
                metadata: definition
            )
            return
        }
        header("\(definition.id): \(definition.title)")
        print(TerminalSanitizer.text(definition.explanation))
        print("\nRecommended action")
        print(TerminalSanitizer.text(definition.recommendedAction))
        print("\nDocumentation")
        print(definition.documentationURL)
    }

    private func resolvedPublicationStage(
        _ explicit: URL?,
        projectRoot: URL
    ) throws -> URL {
        if let explicit { return explicit.standardizedFileURL }
        let releases = projectRoot.appendingPathComponent(".sparklekit/releases")
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: releases,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []
        guard candidates.count == 1, let candidate = candidates.first else {
            throw CLIError.missingArgument(
                "release stage path (required when zero or multiple stages exist)"
            )
        }
        return candidate
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

    private func resolvedValue(
        _ value: String?,
        label: String,
        defaultValue: String?,
        interactive: Bool
    ) throws -> String {
        if interactive {
            return prompt(label, defaultValue: value ?? defaultValue ?? "")
        }
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        throw CLIError.nonInteractiveValueRequired(label)
    }

    private func relativePath(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    private func policyOverrides(from options: Options) throws -> ReleasePolicyOverrides {
        .init(
            releaseMode: try parsedReleaseMode(options.value("release-mode")),
            requireSparkleSignature: options.flag("require-sparkle-signature"),
            requireDeveloperID: options.flag("require-developer-id"),
            requireNotarization: options.flag("require-notarization"),
            allowAdHocSigning: options.flag("allow-ad-hoc-signing"),
            allowUnsigned: options.flag("allow-unsigned")
        )
    }

    private func parsedReleaseMode(_ value: String?) throws -> ReleaseMode? {
        guard let value else { return nil }
        guard let mode = ReleaseMode(rawValue: value) else {
            throw CLIError.invalidValue("release-mode", value)
        }
        return mode
    }

    private func parsedArchitectures(_ value: String?) throws -> [CPUArchitecture]? {
        guard let value else { return nil }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let architectures = parts.compactMap(CPUArchitecture.init(rawValue:))
        guard !parts.isEmpty, architectures.count == parts.count,
            Set(architectures).count == architectures.count
        else {
            throw CLIError.invalidValue("architectures", value)
        }
        return architectures.sorted()
    }

    private func parsedTemplate(_ value: String?) throws -> IntegrationTemplate {
        guard let value else { return .auto }
        guard let template = IntegrationTemplate(rawValue: value.lowercased()) else {
            throw CLIError.invalidValue("template", value)
        }
        return template
    }

    private func printChanges(_ changes: [IntegrationChange]) {
        for change in changes {
            let marker =
                switch change.kind {
                case .create: "+"
                case .update: "~"
                case .unchanged: "="
                }
            let value = "\(marker) \(change.relativePath)  \(change.summary)"
            print("  \(TerminalSanitizer.text(value, preserveNewlines: false))")
        }
    }

    private func printDiagnostics(_ diagnostics: [Diagnostic]) {
        for diagnostic in diagnostics {
            let marker =
                switch diagnostic.severity {
                case .pass: "PASS"
                case .warning: "WARN"
                case .failure: "FAIL"
                }
            print("\n[\(diagnostic.id)] [\(marker)] \(TerminalSanitizer.text(diagnostic.title, preserveNewlines: false))")
            print(TerminalSanitizer.indented(diagnostic.detail, prefix: "       "))
            if let evidence = diagnostic.evidence {
                print(TerminalSanitizer.indented(evidence, prefix: "       Evidence: "))
            }
            if let remediation = diagnostic.remediation {
                print(TerminalSanitizer.indented(remediation, prefix: "       Fix: "))
            }
        }
    }

    private func printEnvelope<T: Encodable>(
        command: String,
        success: Bool,
        diagnostics: [Diagnostic] = [],
        changes: [IntegrationChange] = [],
        artifacts: [CLIArtifact] = [],
        metadata: T
    ) throws {
        let value = JSONEnvelope(
            schemaVersion: "1.0",
            toolVersion: Self.version,
            command: command,
            success: success,
            diagnostics: diagnostics,
            changes: changes,
            artifacts: artifacts,
            metadata: metadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func prompt(_ label: String, defaultValue: String) -> String {
        let suffix = defaultValue.isEmpty ? "" : " [\(defaultValue)]"
        print(TerminalSanitizer.text("\(label)\(suffix): ", preserveNewlines: false), terminator: "")
        return readLine().flatMap { $0.isEmpty ? nil : $0 } ?? defaultValue
    }

    private func promptBoolean(_ label: String, defaultValue: Bool) -> Bool {
        let fallback = defaultValue ? "Y/n" : "y/N"
        let value = prompt("\(label) (\(fallback))", defaultValue: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.isEmpty { return defaultValue }
        return ["y", "yes", "j", "ja"].contains(value)
    }

    private func header(_ title: String) {
        print("\nSparkleReleaseKit")
        print("\(title)\n")
    }

    private func success(_ message: String) {
        print("\nSuccess: \(TerminalSanitizer.text(message, preserveNewlines: false))")
    }
    private func warning(_ message: String) {
        print("\nWarning: \(TerminalSanitizer.text(message, preserveNewlines: false))")
    }
    private func info(_ message: String) {
        print("  \(TerminalSanitizer.text(message, preserveNewlines: false))")
    }
    private func detail(_ label: String, _ value: String) {
        let safeLabel = TerminalSanitizer.text(label, preserveNewlines: false)
        let safeValue = TerminalSanitizer.text(value, preserveNewlines: false)
        print("  \(safeLabel.padding(toLength: 18, withPad: " ", startingAt: 0)) \(safeValue)")
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func printHelp() {
        print(
            """
            SparkleReleaseKit \(Self.version)
            Guided integration, diagnostics, verification, and release staging for Sparkle.

            USAGE
              sparklekit quickstart [project-path] [options]
              sparklekit setup [project-path] [options]
              sparklekit integrate [project-path] [--apply] [--json]
              sparklekit doctor [project-path] [--fix [--apply]] [--json]
              sparklekit test [project-path] --allow-project-execution [--allow-network]
              sparklekit verify <archive.zip|archive.dmg> [--project path] [--json]
              sparklekit verify-update <archive> --appcast PATH --version BUILD [options]
              sparklekit validate-feed <appcast.xml> [--json]
              sparklekit prepare-release <archive> --version X.Y.Z [options]
              sparklekit publish preview [stage-path] [--project PATH] [--json]
              sparklekit explain <diagnostic-id> [--json]

            QUICKSTART AND SETUP OPTIONS
              --owner VALUE       GitHub account or organization
              --repo VALUE        GitHub repository name
              --app-name VALUE    User-facing application name
              --bundle-id VALUE   Reverse-DNS bundle identifier
              --container VALUE   Explicit .xcodeproj or .xcworkspace
              --target VALUE      Explicit application target
              --scheme VALUE      Shared Xcode scheme
              --feed-url VALUE    HTTPS URL to appcast.xml
              --public-key VALUE  Sparkle EdDSA public key (never the private key)
              --release-mode MODE free, developer-id, or auto (default: free)
              --template VALUE    auto, minimal, swiftui, or appkit
              --architectures LIST Comma-separated arm64,x86_64 (default: universal)
              --team-id VALUE     Optional expected 10-character Apple Team ID
              --with-workflow     Generate the GitHub validation workflow
              --interactive       Run the terminal wizard
              --non-interactive   Never prompt for missing values
              --allow-project-execution
                                  Permit xcodebuild-backed project inspection
              --open-xcode        Open the selected container after planning
              --apply             Apply the reviewed plan transactionally
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
              --release-mode MODE         free, developer-id, or auto
              --require-sparkle-signature Require EdDSA update authentication
              --require-developer-id      Fail without Developer ID Application signing
              --require-notarization      Fail without Gatekeeper acceptance and a staple
              --allow-ad-hoc-signing      Permit valid ad-hoc signatures in free/auto mode
              --allow-unsigned            Deliberate unsigned-app release exception
              --allow-project-execution   Permit a reviewed helper inside the target project
              --json                      Emit stable, machine-readable JSON

            TEST OPTIONS
              --allow-project-execution   Permit target build scripts and package plug-ins
              --allow-network             Permit automatic Xcode package resolution

            SAFE DEFAULTS
              quickstart, setup, integrate, doctor --fix, and publish preview do not
              write without their documented explicit approval.
              Target-project execution and automatic package resolution require separate flags.
              prepare-release reads the private EdDSA key from macOS Keychain and
              never accepts private key material in sparklekit.json.
              publish preview never performs a network request or remote write.

            JSON CONTRACT
              schemaVersion, toolVersion, command, success, diagnostics, changes,
              artifacts, and metadata are emitted in a versioned envelope.

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

private struct GuidedSetupDraft {
    var owner: String?
    var repository: String
    var appName: String
    var bundleIdentifier: String
    var target: String
    var scheme: String
    var releaseMode: ReleaseMode
    var template: IntegrationTemplate
    var architectures: [CPUArchitecture]
    var generateWorkflow: Bool
}

private struct SetupReport: Encodable {
    var configurationPath: URL
    var configuration: SparkleKitConfiguration
    var integration: IntegrationResult?
}

private struct DoctorReport: Encodable {
    var fixRequested: Bool
    var applied: Bool
}

private struct TestReport: Encodable {
    var projectExecutionAllowed: Bool
    var networkAllowed: Bool
}

private struct VerifyUpdateReport: Encodable {
    var expectedBuildVersion: String
}

private struct CLIArtifact: Encodable {
    var type: String
    var path: String
}

private struct JSONEnvelope<Metadata: Encodable>: Encodable {
    var schemaVersion: String
    var toolVersion: String
    var command: String
    var success: Bool
    var diagnostics: [Diagnostic]
    var changes: [IntegrationChange]
    var artifacts: [CLIArtifact]
    var metadata: Metadata
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
                    !arguments[index + 1].hasPrefix("--")
                {
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
    case conflictingOptions(String)
    case nonInteractiveValueRequired(String)
    case permissionRequired(String)
    case invalidDiagnosticID(String)
    case externalCommandFailed(String)
    case diagnosticsFailed(Int, jsonWasPrinted: Bool)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command): "Unknown command '\(command)'. Run sparklekit help."
        case .unknownOption(let option): "Unknown option '--\(option)'. Run sparklekit help."
        case .duplicateOption(let option): "Option '--\(option)' was supplied more than once."
        case .unexpectedArgument(let argument): "Unexpected argument '\(argument)'. Run sparklekit help."
        case .missingArgument(let argument): "Missing required \(argument)."
        case .invalidValue(let key, let value): "Invalid value '\(value)' for --\(key)."
        case .conflictingOptions(let detail): "Conflicting options: \(detail)."
        case .nonInteractiveValueRequired(let label): "\(label) is required in non-interactive mode. Pass it explicitly."
        case .permissionRequired(let detail): "Explicit permission required: \(detail)."
        case .invalidDiagnosticID(let id): "Unknown diagnostic ID '\(id)'."
        case .externalCommandFailed(let detail): detail
        case .diagnosticsFailed(let count, _): "\(count) required check(s) failed."
        }
    }

    var exitCode: Int32 {
        switch self {
        case .diagnosticsFailed: 2
        case .externalCommandFailed: 1
        default: 64
        }
    }

    var suppressTextOutput: Bool {
        if case .diagnosticsFailed(_, let jsonWasPrinted) = self { return jsonWasPrinted }
        return false
    }
}
