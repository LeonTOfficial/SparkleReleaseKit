import Foundation

public enum XcodeBuildValidationError: LocalizedError {
    case unsupportedContainer(String)
    case unsafeContainer(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let path):
            "The configured Xcode container must end in .xcodeproj or .xcworkspace: \(path)"
        case .unsafeContainer(let path):
            "The configured Xcode container resolves outside the project root: \(path)"
        }
    }
}

public struct XcodeBuildValidator: Sendable {
    public init() {}

    public func validate(projectRoot: URL, configuration: SparkleKitConfiguration) throws -> [Diagnostic] {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let container = root.appendingPathComponent(configuration.project.container)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard container.path.hasPrefix(rootPath) else {
            throw XcodeBuildValidationError.unsafeContainer(configuration.project.container)
        }
        let containerFlag: String
        switch container.pathExtension.lowercased() {
        case "xcodeproj": containerFlag = "-project"
        case "xcworkspace": containerFlag = "-workspace"
        default: throw XcodeBuildValidationError.unsupportedContainer(configuration.project.container)
        }

        let derivedData = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleReleaseKit-DerivedData-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: derivedData) }
        let common = [
            containerFlag, container.path,
            "-scheme", configuration.project.scheme,
            "-configuration", configuration.project.configuration,
            "-derivedDataPath", derivedData.path,
        ]

        var diagnostics: [Diagnostic] = []
        let listing = try ProcessRunner().run("/usr/bin/xcodebuild", arguments: ["-list", "-json", containerFlag, container.path])
        diagnostics.append(listing.status == 0
            ? .init(.pass, "Xcode project", "Xcode can read the configured container.")
            : .init(.failure, "Xcode project", concise(listing), remediation: "Check project.container and the shared scheme."))
        guard listing.status == 0 else { return diagnostics }

        let resolution = try ProcessRunner().run(
            "/usr/bin/xcodebuild",
            arguments: ["-resolvePackageDependencies"] + common,
            directory: root
        )
        diagnostics.append(resolution.status == 0
            ? .init(.pass, "Package resolution", "Swift package dependencies resolved successfully.")
            : .init(.failure, "Package resolution", concise(resolution), remediation: "Resolve the official Sparkle package in Xcode and retry."))
        guard resolution.status == 0 else { return diagnostics }

        let build = try ProcessRunner().run(
            "/usr/bin/xcodebuild",
            arguments: ["build"] + common + ["CODE_SIGNING_ALLOWED=NO"],
            directory: root
        )
        diagnostics.append(build.status == 0
            ? .init(.pass, "Release build", "The configured scheme builds in \(configuration.project.configuration) without distribution credentials.")
            : .init(.failure, "Release build", concise(build), remediation: "Open the project in Xcode, fix the reported build error, and rerun sparklekit test."))
        return diagnostics
    }

    private func concise(_ result: ProcessResult) -> String {
        let source = result.standardError.isEmpty ? result.standardOutput : result.standardError
        let lines = source.split(separator: "\n", omittingEmptySubsequences: true).suffix(12)
        return lines.isEmpty ? "xcodebuild exited with status \(result.status)." : lines.joined(separator: "\n")
    }
}
