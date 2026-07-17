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
        let projectText = xcodeProjectText(in: root)
        if projectText.contains("github.com/sparkle-project/Sparkle") && projectText.contains("productName = Sparkle") {
            diagnostics.append(.init(.pass, "Official Sparkle package", "The Xcode project references the official Sparkle package and product."))
        } else {
            diagnostics.append(.init(
                .failure,
                "Official Sparkle package",
                "The official Sparkle Swift package is not linked to the project yet.",
                remediation: "Follow SparkleReleaseKit/INTEGRATION.md and add https://github.com/sparkle-project/Sparkle to the app target."
            ))
        }

        diagnostics.append(safeFileDiagnostic(
            "Updater source",
            relativePath: "SparkleReleaseKit/AppUpdater.swift",
            root: root,
            remediation: "Run: sparklekit integrate --apply"
        ))
        diagnostics.append(safeFileDiagnostic(
            "Release workflow",
            relativePath: ".github/workflows/sparkle-release.yml",
            root: root,
            remediation: "Run: sparklekit integrate --apply"
        ))

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
                remediation: "Run: sparklekit integrate --apply"
            ))
        }
        diagnostics.append(contentsOf: inspectTrackedSecrets(root))
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
                results.append(.init(.failure, key, "The expected value is missing or different.", remediation: "Run: sparklekit integrate --apply"))
            }
        }
        return results
    }

    private func commandDiagnostic(_ title: String, path: String) -> Diagnostic {
        FileManager.default.isExecutableFile(atPath: path)
            ? .init(.pass, title, "Available at \(path).")
            : .init(.failure, title, "Not found at \(path).", remediation: "Install the latest stable Xcode command-line tools.")
    }

    private func safeFileDiagnostic(_ title: String, relativePath: String, root: URL, remediation: String) -> Diagnostic {
        do {
            let url = try ProjectPathResolver.resolve(relativePath, under: root)
            return FileManager.default.fileExists(atPath: url.path)
                ? .init(.pass, title, "Found \(url.path).")
                : .init(.failure, title, "Missing \(url.path).", remediation: remediation)
        } catch {
            return .init(.failure, title, error.localizedDescription, remediation: remediation)
        }
    }

    private func xcodeProjectText(in root: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }
        var result = ""
        for case let url as URL in enumerator where url.lastPathComponent == "project.pbxproj" {
            guard ProjectPathResolver.contains(url, in: root) else { continue }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.int64Value <= 32 * 1_024 * 1_024,
               let text = BoundedFileReader.string(at: url, maximumBytes: 32 * 1_024 * 1_024) {
                result += text
            }
        }
        return result
    }

    private func inspectTrackedSecrets(_ root: URL) -> [Diagnostic] {
        guard let files = try? ProcessRunner().run("/usr/bin/git", arguments: ["ls-files"], directory: root),
              files.status == 0 else {
            return [.init(.warning, "Tracked secret scan", "The project is not a readable Git worktree; tracked-file checks were skipped.")]
        }
        let suspiciousNames = files.standardOutput.split(separator: "\n").map(String.init).filter { path in
            let lower = path.lowercased()
            let ext = URL(fileURLWithPath: lower).pathExtension
            return ["p8", "p12"].contains(ext)
                || lower.hasPrefix(".sparklekit/private/")
                || lower.contains("private_key")
                || lower.contains("private-key")
                || lower.contains("secret_key")
                || lower.contains("secret-key")
        }
        if !suspiciousNames.isEmpty {
            return [.init(
                .failure,
                "Tracked secret filenames",
                "Potential private material is tracked in \(suspiciousNames.count) file(s): \(suspiciousNames.prefix(5).joined(separator: ", ")).",
                remediation: "Remove private material from Git history, rotate exposed credentials, and use Keychain or protected CI secrets."
            )]
        }

        let content = try? ProcessRunner().run(
            "/usr/bin/git",
            arguments: ["grep", "-IlE", "BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}", "--", "."],
            directory: root
        )
        if let content, content.status == 0, !content.standardOutput.isEmpty {
            let paths = content.standardOutput.split(separator: "\n").prefix(5).joined(separator: ", ")
            return [.init(
                .failure,
                "Tracked secret contents",
                "Potential credential material appears in tracked file(s): \(paths).",
                remediation: "Treat the credential as exposed, rotate it, and remove it from repository history."
            )]
        }
        if let content, content.status > 1 {
            return [.init(.warning, "Tracked secret contents", "git grep could not complete: \(content.standardError)")]
        }
        return [.init(.pass, "Tracked secret scan", "No private-key headers or common token formats were found in tracked files.")]
    }
}
