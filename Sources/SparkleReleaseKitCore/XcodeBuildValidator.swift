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

    public func validate(
        projectRoot: URL,
        configuration: SparkleKitConfiguration,
        allowNetwork: Bool = false
    ) throws -> [Diagnostic] {
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
        let offline = allowNetwork ? [] : ["-disableAutomaticPackageResolution"]
        let environment = safeBuildEnvironment()

        var diagnostics: [Diagnostic] = []
        let listing = try ProcessRunner().run(
            "/usr/bin/xcodebuild",
            arguments: ["-list", "-json"] + offline + [containerFlag, container.path],
            directory: root,
            environment: environment,
            inheritEnvironment: false,
            timeout: 120
        )
        diagnostics.append(succeeded(listing)
            ? .init(.pass, "Xcode project", "Xcode can read the configured container.")
            : .init(.failure, "Xcode project", concise(listing), remediation: "Check project.container and the shared scheme."))
        guard succeeded(listing) else { return diagnostics }

        if allowNetwork {
            let resolution = try ProcessRunner().run(
                "/usr/bin/xcodebuild",
                arguments: ["-resolvePackageDependencies"] + common,
                directory: root,
                environment: environment,
                inheritEnvironment: false,
                timeout: 600
            )
            diagnostics.append(succeeded(resolution)
                ? .init(.pass, "Package resolution", "Swift package dependencies resolved successfully.")
                : .init(.failure, "Package resolution", concise(resolution), remediation: "Resolve the official Sparkle package in Xcode and retry."))
            guard succeeded(resolution) else { return diagnostics }
        } else {
            diagnostics.append(.init(
                .warning,
                "Package network access",
                "Automatic package resolution is disabled for this test run.",
                remediation: "Pass --allow-network only when package downloads are required and the project is trusted."
            ))
        }

        let build = try ProcessRunner().run(
            "/usr/bin/xcodebuild",
            arguments: ["build"] + common + offline + ["CODE_SIGNING_ALLOWED=NO"],
            directory: root,
            environment: environment,
            inheritEnvironment: false,
            timeout: 900
        )
        diagnostics.append(succeeded(build)
            ? .init(.pass, "Release build", "The configured scheme builds in \(configuration.project.configuration) without distribution credentials.")
            : .init(.failure, "Release build", concise(build), remediation: "Open the project in Xcode, fix the reported build error, and rerun sparklekit test."))
        return diagnostics
    }

    private func succeeded(_ result: ProcessResult) -> Bool {
        result.status == 0
            && !result.timedOut
            && !result.standardOutputTruncated
            && !result.standardErrorTruncated
    }

    private func concise(_ result: ProcessResult) -> String {
        if result.timedOut {
            return "xcodebuild exceeded the configured timeout and was terminated."
        }
        if result.standardOutputTruncated || result.standardErrorTruncated {
            return "xcodebuild output exceeded the capture limit; the result is treated as incomplete."
        }
        let source = result.standardError.isEmpty ? result.standardOutput : result.standardError
        let lines = source.split(separator: "\n", omittingEmptySubsequences: true).suffix(12)
        return lines.isEmpty ? "xcodebuild exited with status \(result.status)." : lines.joined(separator: "\n")
    }

    private func safeBuildEnvironment() -> [String: String] {
        let ambient = ProcessInfo.processInfo.environment
        var result = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": ambient["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": ambient["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
        ]
        for name in ["DEVELOPER_DIR", "TOOLCHAINS", "LANG", "LC_ALL"] {
            if let value = ambient[name] { result[name] = value }
        }
        return result
    }
}
