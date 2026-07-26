import Foundation

public struct Doctor: Sendable {
    public init() {}

    public func inspect(
        projectRoot: URL,
        configuration: SparkleKitConfiguration?,
        configurationError: String? = nil
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        diagnostics.append(commandDiagnostic("Xcode command-line tools", path: "/usr/bin/xcodebuild"))
        diagnostics.append(commandDiagnostic("Git", path: "/usr/bin/git"))

        guard let configuration else {
            diagnostics.append(.init(
                .failure,
                "Configuration",
                configurationError ?? "sparklekit.json is missing.",
                remediation: configurationError == nil
                    ? "Run sparklekit setup from the project root."
                    : "Repair sparklekit.json, then run doctor again."
            ))
            return diagnostics
        }

        do {
            try ConfigurationStore().validate(configuration)
            diagnostics.append(.init(.pass, "Configuration", "The configuration is valid and uses an HTTPS feed."))
        } catch {
            diagnostics.append(.init(.failure, "Configuration", error.localizedDescription, remediation: "Edit sparklekit.json and run doctor again."))
        }

        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        diagnostics.append(safeFileDiagnostic(
            "Xcode container",
            relativePath: configuration.project.container,
            root: root,
            remediation: "Update project.container in sparklekit.json."
        ))
        let projectText = xcodeProjectText(in: root, configuration: configuration)
        if projectText.contains("github.com/sparkle-project/Sparkle") && projectText.contains("productName = Sparkle") {
            diagnostics.append(.init(.pass, "Official Sparkle package", "The Xcode project references the official Sparkle package and product."))
        } else {
            diagnostics.append(.init(
                .failure,
                "Official Sparkle package",
                "The official Sparkle Swift package is not linked to the project yet.",
                remediation: "Follow SparkleReleaseKit/INTEGRATION.md and add https://github.com/sparkle-project/Sparkle to the app target.",
                id: "SRK1001",
                affectedComponent: configuration.project.target ?? configuration.app.name,
                evidence: configuration.project.container
            ))
        }

        if detectsCustomSparkleIntegration(in: root) {
            diagnostics.append(
                .init(
                    .warning,
                    "Existing custom Sparkle integration",
                    "Updater code already exists in the project. SparkleReleaseKit will preserve it and will not silently replace custom behavior.",
                    remediation: "Review the existing updater, delegate, channels, and UI before applying generated files.",
                    id: "SRK1103",
                    affectedComponent: configuration.project.target ?? configuration.app.name,
                    documentationURL: DiagnosticCatalog.definition(for: "SRK1103")?.documentationURL
                ))
        }

        diagnostics.append(safeFileDiagnostic(
            "Updater source",
            relativePath: "SparkleReleaseKit/AppUpdater.swift",
            root: root,
            remediation: "Run: sparklekit doctor --fix --apply",
            automaticFixAvailable: true
        ))
        if configuration.project.generateWorkflow {
            diagnostics.append(safeFileDiagnostic(
                "Release workflow",
                relativePath: ".github/workflows/sparkle-release.yml",
                root: root,
                remediation: "Run: sparklekit doctor --fix --apply",
                automaticFixAvailable: true
            ))
        }

        if let relativePlist = configuration.project.infoPlist {
            do {
                let plist = try ProjectPathResolver.resolve(relativePlist, under: root)
                diagnostics.append(contentsOf: inspectInfoPlist(plist, configuration: configuration))
            } catch {
                diagnostics.append(.init(
                    .failure,
                    "Info.plist path",
                    error.localizedDescription,
                    remediation: "Keep project.infoPlist inside the project root and remove escaping symbolic links."
                ))
            }
        } else {
            let hasFeed = projectText.contains("INFOPLIST_KEY_SUFeedURL") && projectText.contains(configuration.updates.feedURL)
            let hasKey = projectText.contains("INFOPLIST_KEY_SUPublicEDKey") && projectText.contains(configuration.updates.publicEDKey)
            diagnostics.append(hasFeed && hasKey
                ? .init(.pass, "Generated Info.plist settings", "The Sparkle feed and public key are present in Xcode build settings.")
                : .init(
                    .failure,
                    "Generated Info.plist settings",
                    "This target uses generated Info.plist values, but the Sparkle feed or public key is missing.",
                    remediation: "Follow SparkleReleaseKit/INTEGRATION.md and add SUFeedURL and SUPublicEDKey in the target's Info properties."
                ))
        }

        let gitignore = try? ProjectPathResolver.resolve(".gitignore", under: root)
        if let gitignore,
           let content = BoundedFileReader.string(at: gitignore, maximumBytes: 1_024 * 1_024),
           content.contains(".sparklekit/private") {
            diagnostics.append(.init(.pass, "Secret protection", "Private SparkleKit material is excluded by .gitignore."))
        } else {
            diagnostics.append(.init(
                .warning,
                "Secret protection",
                ".gitignore does not yet exclude .sparklekit/private/.",
                remediation: "Run: sparklekit doctor --fix --apply",
                automaticFixAvailable: true
            ))
        }
        do {
            try validateNoTrackedSecrets(root)
            diagnostics.append(.init(.pass, "Tracked secret scan", "No private-key headers or common token formats were found in tracked files."))
        } catch let issue as TrackedSecretScanIssue {
            switch issue {
            case .notGitWorktree:
                diagnostics.append(.init(.warning, "Tracked secret scan", "The project is not a readable Git worktree; tracked-file checks were skipped."))
            case .suspiciousFilename:
                diagnostics.append(.init(
                    .failure,
                    "Tracked secret filenames",
                    "Potential private material is tracked in one or more files. Paths are intentionally omitted from diagnostic output.",
                    remediation: "Remove private material from Git history, rotate exposed credentials, and use Keychain or protected CI secrets."
                ))
            case .suspiciousContents:
                diagnostics.append(.init(
                    .failure,
                    "Tracked secret contents",
                    "Potential credential material appears in one or more tracked files. Paths and matched content are intentionally omitted from diagnostic output.",
                    remediation: "Treat the credential as exposed, rotate it, and remove it from repository history."
                ))
            case .contentScanFailed:
                diagnostics.append(.init(.warning, "Tracked secret contents", "The tracked-file content scan could not complete. Command output is intentionally omitted."))
            }
        } catch {
            diagnostics.append(.init(.warning, "Tracked secret scan", "The tracked-file scan stopped unexpectedly without exposing command output."))
        }
        return diagnostics
    }

    private func inspectInfoPlist(_ url: URL, configuration: SparkleKitConfiguration) -> [Diagnostic] {
        guard let data = BoundedFileReader.data(at: url, maximumBytes: 1_024 * 1_024),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            return [.init(.failure, "Info.plist", "The plist could not be read at \(url.path).")]
        }

        var results: [Diagnostic] = []
        let expected: [String: String] = [
            "SUFeedURL": configuration.updates.feedURL,
            "SUPublicEDKey": configuration.updates.publicEDKey,
        ]
        for (key, value) in expected {
            if dictionary[key] as? String == value {
                results.append(.init(.pass, key, "The expected value is present in Info.plist."))
            } else {
                results.append(
                    .init(
                        .failure,
                        key,
                        "The expected value is missing or different.",
                        remediation: "Run: sparklekit doctor --fix --apply",
                        affectedComponent: url.path,
                        automaticFixAvailable: true
                    ))
            }
        }
        return results
    }

    private func commandDiagnostic(_ title: String, path: String) -> Diagnostic {
        FileManager.default.isExecutableFile(atPath: path)
            ? .init(.pass, title, "Available at \(path).")
            : .init(.failure, title, "Not found at \(path).", remediation: "Install the latest stable Xcode command-line tools.")
    }

    private func safeFileDiagnostic(
        _ title: String,
        relativePath: String,
        root: URL,
        remediation: String,
        automaticFixAvailable: Bool = false
    ) -> Diagnostic {
        do {
            let url = try ProjectPathResolver.resolveForWrite(relativePath, under: root)
            return FileManager.default.fileExists(atPath: url.path)
                ? .init(.pass, title, "Found \(url.path).")
                : .init(
                    .failure,
                    title,
                    "Missing \(url.path).",
                    remediation: remediation,
                    affectedComponent: relativePath,
                    automaticFixAvailable: automaticFixAvailable
                )
        } catch {
            return .init(.failure, title, error.localizedDescription, remediation: remediation)
        }
    }

    private func xcodeProjectText(
        in root: URL,
        configuration: SparkleKitConfiguration
    ) -> String {
        guard let container = try? ProjectPathResolver.resolve(
            configuration.project.container,
            under: root
        ) else { return "" }
        let projects: [URL]
        if container.pathExtension == "xcodeproj" {
            projects = [container]
        } else {
            let workspace = container.appendingPathComponent("contents.xcworkspacedata")
            guard let text = BoundedFileReader.string(at: workspace, maximumBytes: 1_024 * 1_024),
                  let expression = try? NSRegularExpression(
                    pattern: #"location\s*=\s*"group:([^"]+\.xcodeproj)""#
                  ) else { return "" }
            projects = expression.matches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ).prefix(16).compactMap { match in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return try? ProjectPathResolver.resolve(
                    String(text[range]),
                    under: root
                )
            }
        }
        return projects.prefix(16).compactMap {
            BoundedFileReader.string(
                at: $0.appendingPathComponent("project.pbxproj"),
                maximumBytes: 32 * 1_024 * 1_024
            )
        }.joined(separator: "\n")
    }

    private func detectsCustomSparkleIntegration(in root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        var files = 0
        var bytes = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files += 1
            guard files <= 10_000 else { return false }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size <= 8 * 1_024 * 1_024,
                  bytes <= 64 * 1_024 * 1_024 - size,
                  let text = BoundedFileReader.string(at: url, maximumBytes: 8 * 1_024 * 1_024)
            else { continue }
            bytes += size
            if !text.contains("Generated by SparkleReleaseKit")
                && (text.contains("SPUStandardUpdaterController")
                || text.contains("SPUUpdaterDelegate")
                || text.contains("SUUpdater"))
            {
                return true
            }
        }
        return false
    }

    private enum TrackedSecretScanIssue: Error {
        case notGitWorktree
        case suspiciousFilename
        case suspiciousContents
        case contentScanFailed
    }

    private func validateNoTrackedSecrets(_ root: URL) throws {
        guard let files = try? ProcessRunner().run("/usr/bin/git", arguments: ["ls-files"], directory: root),
              files.status == 0,
              !files.timedOut,
              !files.standardOutputTruncated,
              !files.standardErrorTruncated else {
            throw TrackedSecretScanIssue.notGitWorktree
        }
        let hasSuspiciousName = files.standardOutput.split(separator: "\n").contains { path in
            let lower = path.lowercased()
            let ext = URL(fileURLWithPath: lower).pathExtension
            return ["p8", "p12"].contains(ext)
                || lower.hasPrefix(".sparklekit/private/")
                || lower.contains("private_key")
                || lower.contains("private-key")
                || lower.contains("secret_key")
                || lower.contains("secret-key")
        }
        if hasSuspiciousName { throw TrackedSecretScanIssue.suspiciousFilename }

        let content = try? ProcessRunner().run(
            "/usr/bin/git",
            arguments: ["grep", "-IlE", "BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}", "--", "."],
            directory: root
        )
        if let content, content.status == 0, !content.standardOutput.isEmpty {
            throw TrackedSecretScanIssue.suspiciousContents
        }
        if content == nil
            || content?.status ?? 0 > 1
            || content?.timedOut == true
            || content?.standardOutputTruncated == true
            || content?.standardErrorTruncated == true
        {
            throw TrackedSecretScanIssue.contentScanFailed
        }
    }
}
