import Foundation

public enum ProjectDetectionError: LocalizedError {
    case pathNotFound(URL)
    case noXcodeContainer(URL)
    case ambiguousContainers([String])
    case containerNotFound(String)
    case ambiguousSchemes([String])
    case schemeNotFound(String)
    case ambiguousApplicationTargets([String])
    case applicationTargetNotFound(String)
    case unsafeProjectReference(String)

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let url):
            "The project path does not exist: \(url.path)"
        case .noXcodeContainer(let url):
            "No .xcodeproj or .xcworkspace was found in \(url.path)."
        case .ambiguousContainers(let names):
            "Multiple Xcode containers were found (\(names.joined(separator: ", "))). Select one explicitly."
        case .containerNotFound(let name):
            "The selected Xcode container was not found: \(name)"
        case .ambiguousSchemes(let names):
            "Multiple shared schemes were found (\(names.joined(separator: ", "))). Pass --scheme explicitly."
        case .schemeNotFound(let name):
            "The selected shared scheme was not found: \(name)"
        case .ambiguousApplicationTargets(let names):
            "Multiple application targets were found (\(names.joined(separator: ", "))). Pass --target explicitly."
        case .applicationTargetNotFound(let name):
            "The selected application target was not found: \(name)"
        case .unsafeProjectReference(let path):
            "The project contains an unsafe reference outside its root: \(path)"
        }
    }
}

public struct ProjectDetectionOptions: Equatable, Sendable {
    public var allowProjectExecution: Bool
    public var container: String?
    public var scheme: String?
    public var target: String?

    public init(
        allowProjectExecution: Bool = false,
        container: String? = nil,
        scheme: String? = nil,
        target: String? = nil
    ) {
        self.allowProjectExecution = allowProjectExecution
        self.container = container
        self.scheme = scheme
        self.target = target
    }
}

public struct ProjectDetector {
    private let fileManager = FileManager.default

    public init() {}

    public func detect(
        at inputURL: URL,
        options: ProjectDetectionOptions = .init()
    ) throws -> DetectedProject {
        let root = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectDetectionError.pathNotFound(root)
        }

        let container = try findContainer(in: root, preferred: options.container)
        let projectURL = container.pathExtension == "xcodeproj"
            ? container
            : try findProjectReferencedByWorkspace(container, root: root) ?? findProject(in: root)
        let projectText = projectURL.flatMap { readText(at: $0.appendingPathComponent("project.pbxproj"), maximumBytes: 32 * 1_024 * 1_024) } ?? ""
        let fallbackAppName = inferredAppName(projectText: projectText, container: container)
        let target = try selectedApplicationTarget(in: projectText, preferred: options.target)
        let scheme = try selectedSharedScheme(
            in: container,
            projectURL: projectURL,
            preferred: options.scheme,
            fallback: target ?? fallbackAppName
        )
        let buildSettings = options.allowProjectExecution
            ? resolvedBuildSettings(container: container, scheme: scheme, target: target, root: root)
            : nil
        let appName = cleanResolvedSetting(buildSettings?["PRODUCT_NAME"]) ?? target ?? fallbackAppName
        let bundleIdentifier = cleanResolvedSetting(buildSettings?["PRODUCT_BUNDLE_IDENTIFIER"])
            ?? capture("PRODUCT_BUNDLE_IDENTIFIER\\s*=\\s*([^;]+);", in: projectText)
            .map(cleanBuildSetting) ?? "com.example.\(slug(appName))"
        let minimumMacOS = cleanResolvedSetting(buildSettings?["MACOSX_DEPLOYMENT_TARGET"]) ?? "13.0"
        let infoPlist = resolveInfoPlist(buildSettings: buildSettings, projectText: projectText, root: root)
        let sandboxed = detectSandbox(
            buildSettings: buildSettings,
            projectText: projectText,
            root: root
        )
        let style = detectStyle(in: root)
        let remote = gitHubRemote(in: root)

        return DetectedProject(
            rootURL: root,
            containerURL: container,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            minimumMacOS: minimumMacOS,
            scheme: scheme,
            targetName: target ?? appName,
            infoPlistURL: infoPlist,
            style: style,
            sandboxed: sandboxed,
            githubOwner: remote?.owner,
            githubRepository: remote?.repository
        )
    }

    private func findContainer(in root: URL, preferred: String?) throws -> URL {
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let containers = children.filter {
            ["xcodeproj", "xcworkspace"].contains($0.pathExtension)
                && ProjectPathResolver.contains($0, in: root)
        }
        if let preferred {
            let selected = try ProjectPathResolver.resolve(preferred, under: root, fileManager: fileManager)
            guard containers.contains(where: { $0.standardizedFileURL == selected.standardizedFileURL }) else {
                throw ProjectDetectionError.containerNotFound(preferred)
            }
            return selected
        }
        let workspaces = containers.filter { $0.pathExtension == "xcworkspace" }
        let candidates = workspaces.isEmpty
            ? containers.filter { $0.pathExtension == "xcodeproj" }
            : workspaces
        guard !candidates.isEmpty else { throw ProjectDetectionError.noXcodeContainer(root) }
        guard candidates.count == 1, let selected = candidates.first else {
            throw ProjectDetectionError.ambiguousContainers(candidates.map(\.lastPathComponent))
        }
        return selected
    }

    private func findProject(in root: URL) -> URL? {
        (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "xcodeproj" && ProjectPathResolver.contains($0, in: root) }
            .sorted { $0.path < $1.path }
            .first
    }

    private func findProjectReferencedByWorkspace(_ workspace: URL, root: URL) throws -> URL? {
        let contents = workspace.appendingPathComponent("contents.xcworkspacedata")
        guard let text = readText(at: contents, maximumBytes: 1_024 * 1_024),
              let location = capture("location\\s*=\\s*\"group:([^\"]+\\.xcodeproj)\"", in: text) else {
            return nil
        }
        do {
            return try ProjectPathResolver.resolve(location, under: root, fileManager: fileManager)
        } catch {
            throw ProjectDetectionError.unsafeProjectReference(location)
        }
    }

    private func inferredAppName(projectText: String, container: URL) -> String {
        if let name = capture("PRODUCT_NAME\\s*=\\s*([^;]+);", in: projectText) {
            let cleaned = cleanBuildSetting(name)
            if !cleaned.contains("$(") { return cleaned }
        }
        return container.deletingPathExtension().lastPathComponent
    }

    private func resolveInfoPlist(buildSettings: [String: String]?, projectText: String, root: URL) -> URL? {
        guard var value = cleanResolvedSetting(buildSettings?["INFOPLIST_FILE"])
            ?? capture("INFOPLIST_FILE\\s*=\\s*([^;]+);", in: projectText) else { return nil }
        value = cleanBuildSetting(value)
        value = value.replacingOccurrences(of: "$(SRCROOT)/", with: "")
        value = value.replacingOccurrences(of: "$(PROJECT_DIR)/", with: "")
        guard !value.contains("$(") else { return nil }
        guard !value.hasPrefix("/"),
              let url = try? ProjectPathResolver.resolve(value, under: root, fileManager: fileManager) else {
            return nil
        }
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func detectSandbox(
        buildSettings: [String: String]?,
        projectText: String,
        root: URL
    ) -> Bool? {
        guard var value = cleanResolvedSetting(buildSettings?["CODE_SIGN_ENTITLEMENTS"])
            ?? capture("CODE_SIGN_ENTITLEMENTS\\s*=\\s*([^;]+);", in: projectText)
        else { return false }
        value = cleanBuildSetting(value)
            .replacingOccurrences(of: "$(SRCROOT)/", with: "")
            .replacingOccurrences(of: "$(PROJECT_DIR)/", with: "")
        guard !value.contains("$("),
              !value.hasPrefix("/"),
              let url = try? ProjectPathResolver.resolve(value, under: root, fileManager: fileManager),
              let data = BoundedFileReader.data(at: url, maximumBytes: 1_024 * 1_024),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entitlements = plist as? [String: Any] else { return nil }
        return entitlements["com.apple.security.app-sandbox"] as? Bool ?? false
    }

    private func resolvedBuildSettings(
        container: URL,
        scheme: String,
        target: String?,
        root: URL
    ) -> [String: String]? {
        let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        let ambient = ProcessInfo.processInfo.environment
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": ambient["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": ambient["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
        ]
        for name in ["DEVELOPER_DIR", "TOOLCHAINS", "LANG", "LC_ALL"] {
            if let value = ambient[name] { environment[name] = value }
        }
        guard let result = try? ProcessRunner().run(
            "/usr/bin/xcodebuild",
            arguments: [
                "-showBuildSettings", "-json", "-disableAutomaticPackageResolution",
                flag, container.path, "-scheme", scheme,
            ],
            directory: root,
            environment: environment,
            inheritEnvironment: false,
            timeout: 120
        ), result.status == 0, !result.timedOut, !result.standardOutputTruncated,
        let data = result.standardOutput.data(using: .utf8),
        let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let app = entries.first { entry in
            if let target, entry["target"] as? String != target { return false }
            guard let settings = entry["buildSettings"] as? [String: String] else { return false }
            return settings["WRAPPER_EXTENSION"] == "app" || settings["PRODUCT_TYPE"] == "com.apple.product-type.application"
        } ?? entries.first
        return app?["buildSettings"] as? [String: String]
    }

    private func cleanResolvedSetting(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = cleanBuildSetting(value)
        return cleaned.isEmpty || cleaned.contains("$(") ? nil : cleaned
    }

    private func detectStyle(in root: URL) -> AppStyle {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return .unknown }

        var foundAppKit = false
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard ProjectPathResolver.contains(url, in: root),
                  let text = readText(at: url, maximumBytes: 8 * 1_024 * 1_024) else { continue }
            if text.contains("import SwiftUI") || text.contains("@main") && text.contains(": App") {
                return .swiftUI
            }
            foundAppKit = foundAppKit || text.contains("import AppKit")
        }
        return foundAppKit ? .appKit : .unknown
    }

    private func selectedSharedScheme(
        in container: URL,
        projectURL: URL?,
        preferred: String?,
        fallback: String
    ) throws -> String {
        let bases = [container, projectURL].compactMap { $0 }
        var names: Set<String> = []
        for base in bases {
            let schemes = base.appendingPathComponent("xcshareddata/xcschemes")
            let files = try? fileManager.contentsOfDirectory(at: schemes, includingPropertiesForKeys: nil)
            for file in files ?? [] where file.pathExtension == "xcscheme"
                && ProjectPathResolver.contains(file, in: base)
            {
                names.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        let sorted = names.sorted()
        if let preferred {
            guard sorted.isEmpty || names.contains(preferred) else {
                throw ProjectDetectionError.schemeNotFound(preferred)
            }
            return preferred
        }
        guard sorted.count <= 1 else {
            throw ProjectDetectionError.ambiguousSchemes(sorted)
        }
        return sorted.first ?? fallback
    }

    private func selectedApplicationTarget(in projectText: String, preferred: String?) throws -> String? {
        let targets = applicationTargets(in: projectText)
        if let preferred {
            guard targets.isEmpty || targets.contains(preferred) else {
                throw ProjectDetectionError.applicationTargetNotFound(preferred)
            }
            return preferred
        }
        guard targets.count <= 1 else {
            throw ProjectDetectionError.ambiguousApplicationTargets(targets)
        }
        return targets.first
    }

    private func applicationTargets(in projectText: String) -> [String] {
        guard let objectPattern = try? NSRegularExpression(
            pattern: #"(?s)isa\s*=\s*PBXNativeTarget;(.*?)(?:\n\s*};)"#
        ) else { return [] }
        let matches = objectPattern.matches(
            in: projectText,
            range: NSRange(projectText.startIndex..., in: projectText)
        )
        var targets: Set<String> = []
        for match in matches {
            guard let bodyRange = Range(match.range(at: 1), in: projectText) else { continue }
            let body = String(projectText[bodyRange])
            guard body.range(
                of: #"productType\s*=\s*"?com\.apple\.product-type\.application"?\s*;"#,
                options: .regularExpression
            ) != nil,
            let name = capture(#"name\s*=\s*([^;]+);"#, in: body)
            else { continue }
            let cleaned = cleanBuildSetting(name)
            if !cleaned.isEmpty { targets.insert(cleaned) }
        }
        return targets.sorted()
    }

    private func gitHubRemote(in root: URL) -> (owner: String, repository: String)? {
        guard let result = try? ProcessRunner().run("/usr/bin/git", arguments: ["remote", "get-url", "origin"], directory: root),
              result.status == 0, !result.timedOut, !result.standardOutputTruncated else { return nil }
        let remote = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if remote.hasPrefix("git@github.com:") {
            path = String(remote.dropFirst("git@github.com:".count))
        } else if let url = URL(string: remote),
                  url.host?.lowercased() == "github.com",
                  ["https", "ssh"].contains(url.scheme?.lowercased() ?? "") {
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return nil
        }

        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        let repository = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard !parts[0].isEmpty, !repository.isEmpty else { return nil }
        return (parts[0], repository)
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func cleanBuildSetting(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\""))
    }

    private func slug(_ value: String) -> String {
        let allowed = value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : Character("-") }
        return String(allowed).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
    }

    private func readText(at url: URL, maximumBytes: Int) -> String? {
        BoundedFileReader.string(at: url, maximumBytes: maximumBytes)
    }
}
