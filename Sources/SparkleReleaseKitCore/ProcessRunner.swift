import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct ProcessRunner: Sendable {
    public init() {}

    @discardableResult
    public func run(
        _ executable: String,
        arguments: [String],
        directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        // File-backed capture cannot deadlock when verbose tools such as xcodebuild
        // produce more output than an in-memory pipe can buffer.
        let captureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleReleaseKit-Process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: captureRoot) }

        let stdoutURL = captureRoot.appendingPathComponent("stdout")
        let stderrURL = captureRoot.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw error
        }

        let stdout = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderr = (try? Data(contentsOf: stderrURL)) ?? Data()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
