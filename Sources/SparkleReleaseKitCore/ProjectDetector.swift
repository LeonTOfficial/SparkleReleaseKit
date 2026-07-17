import Foundation

public enum ProjectDetectionError: LocalizedError {
    case pathNotFound(URL)
    case noXcodeContainer(URL)
    case unsafeProjectReference(String)

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let url):
            "The project path does not exist: \(url.path)"
        case .noXcodeContainer(let url):
            "No .xcodeproj or .xcworkspace was found in \(url.path)."
        case .unsafeProjectReference(let path):
            "The project contains an unsafe reference outside its root: \(path)"
        }
    }
}

public struct ProjectDetector {
    private let fileManager = FileManager.default

    public init() {}

    public func detect(at inputURL: URL) throws -> DetectedProject {
        let root = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectDetectionError.pathNotFound(root)
        }

        let container = try findContainer(in: root)
        let projectURL = container.pathExtension == "xcodeproj"
            ? container
            : try findProjectReferencedByWorkspace(container, root: root) ?? findProject(in: root)
        let projectText = projectURL.flatMap { readText(at: $0.appendingPathComponent("project.pbxproj"), maximumBytes: 32 * 1_024 * 1_024) } ?? ""
        let fallbackAppName = inferredAppName(projectText: projectText, container: container)
        let scheme = findSharedScheme(in: container, projectURL: projectURL) ?? fallbackAppName
        let buildSettings = resolvedBuildSettings(container: container, scheme: scheme, root: root)
        let appName = cleanResolvedSetting(buildSettings?["PRODUCT_NAME"]) ?? fallbackAppName
        let bundleIdentifier = cleanResolvedSetting(buildSettings?["PRODUCT_BUNDLE_IDENTIFIER"])
            ?? capture("PRODUCT_BUNDLE_IDENTIFIER\\s*=\\s*([^;]+);", in: projectText)
            .map(cleanBuildSetting) ?? "com.example.\(slug(appName))"
        let minimumMacOS = cleanResolvedSetting(buildSettings?["MACOSX_DEPLOYMENT_TARGET"]) ?? "13.0"
        let infoPlist = resolveInfoPlist(buildSettings: buildSettings, projectText: projectText, root: root)
        let style = detectStyle(in: root)
        let remote = gitHubRemote(in: root)

        return DetectedProject(
            rootURL: root,
            containerURL: container,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            minimumMacOS: minimumMacOS,
            scheme: scheme,
            infoPlistURL: infoPlist,
            style: style,
            githubOwner: remote?.owner,
            githubRepository: remote?.repository
        )
    }

    private func findContainer(in root: URL) throws -> URL {
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if let workspace = children.first(where: {
            $0.pathExtension == "xcworkspace" && ProjectPathResolver.contains($0, in: root)
        }) {
            return workspace
        }
        if let project = children.first(where: {
            $0.pathExtension == "xcodeproj" && ProjectPathResolver.contains($0, in: root)
        }) {
            return project
        }
        throw ProjectDetectionError.noXcodeContainer(root)
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

    private func resolvedBuildSettings(container: URL, scheme: String, root: URL) -> [String: String]? {
        let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        guard let result = try? ProcessRunner().run(
            "/usr/bin/xcodebuild",
            arguments: ["-showBuildSettings", "-json", flag, container.path, "-scheme", scheme],
            directory: root
        ), result.status == 0,
        let data = result.standardOutput.data(using: .utf8),
        let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let app = entries.first { entry in
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

    private func findSharedScheme(in container: URL, projectURL: URL?) -> String? {
        let bases = [container, projectURL].compactMap { $0 }
        for base in bases {
            let schemes = base.appendingPathComponent("xcshareddata/xcschemes")
            let files = try? fileManager.contentsOfDirectory(at: schemes, includingPropertiesForKeys: nil)
            if let file = files?
                .filter({ $0.pathExtension == "xcscheme" && ProjectPathResolver.contains($0, in: base) })
                .sorted(by: { $0.path < $1.path })
                .first {
                return file.deletingPathExtension().lastPathComponent
            }
        }
        return nil
    }

    private func gitHubRemote(in root: URL) -> (owner: String, repository: String)? {
        guard let result = try? ProcessRunner().run("/usr/bin/git", arguments: ["remote", "get-url", "origin"], directory: root),
              result.status == 0 else { return nil }
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
