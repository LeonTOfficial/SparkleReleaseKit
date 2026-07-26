import Darwin
import Foundation

public enum ProcessRunnerError: LocalizedError, Equatable {
    case invalidTimeout
    case couldNotTerminate(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "Process timeout must be a finite value greater than zero."
        case .couldNotTerminate(let pid):
            "Process \(pid) did not stop after the timeout and forced termination."
        }
    }
}

public struct ProcessResult: Sendable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String
    public var timedOut: Bool
    public var standardOutputTruncated: Bool
    public var standardErrorTruncated: Bool
    public var standardOutputBytes: UInt64
    public var standardErrorBytes: UInt64

    public init(
        status: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool = false,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false,
        standardOutputBytes: UInt64 = 0,
        standardErrorBytes: UInt64 = 0
    ) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
        self.standardOutputBytes = standardOutputBytes
        self.standardErrorBytes = standardErrorBytes
    }
}

public struct ProcessRunner: Sendable {
    private static let maximumCapturedBytes = 8 * 1_024 * 1_024
    private static let capturedEdgeBytes = maximumCapturedBytes / 2
    private static let terminationGracePeriod: TimeInterval = 2

    public init() {}

    @discardableResult
    public func run(
        _ executable: String,
        arguments: [String],
        directory: URL? = nil,
        environment: [String: String]? = nil,
        inheritEnvironment: Bool = true,
        timeout: TimeInterval = 300
    ) throws -> ProcessResult {
        guard timeout > 0, timeout.isFinite else {
            throw ProcessRunnerError.invalidTimeout
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        if inheritEnvironment, let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        } else if !inheritEnvironment {
            process.environment = environment ?? [:]
        }

        // File-backed capture cannot deadlock when verbose tools such as xcodebuild
        // produce more output than an in-memory pipe can buffer.
        let captureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleReleaseKit-Process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: captureRoot.path)
        defer { try? FileManager.default.removeItem(at: captureRoot) }

        let stdoutURL = captureRoot.appendingPathComponent("stdout")
        let stderrURL = captureRoot.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        var timedOut = false
        do {
            try process.run()
            let pid = process.processIdentifier
            let ownsProcessGroup = setpgid(pid, pid) == 0
            if completion.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                Self.signal(process: process, signal: SIGTERM, processGroup: ownsProcessGroup)
                if completion.wait(timeout: .now() + Self.terminationGracePeriod) == .timedOut {
                    Self.signal(process: process, signal: SIGKILL, processGroup: ownsProcessGroup)
                    guard completion.wait(timeout: .now() + Self.terminationGracePeriod) == .success else {
                        throw ProcessRunnerError.couldNotTerminate(pid)
                    }
                }
            }
            try stdoutHandle.close()
            try stderrHandle.close()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw error
        }

        let stdout = (try? Self.readCapturedOutput(at: stdoutURL)) ?? .empty
        let stderr = (try? Self.readCapturedOutput(at: stderrURL)) ?? .empty
        return ProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            standardOutput: String(decoding: stdout.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: String(decoding: stderr.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut,
            standardOutputTruncated: stdout.truncated,
            standardErrorTruncated: stderr.truncated,
            standardOutputBytes: stdout.totalBytes,
            standardErrorBytes: stderr.totalBytes
        )
    }

    private struct CapturedOutput {
        var data: Data
        var truncated: Bool
        var totalBytes: UInt64

        static let empty = CapturedOutput(data: Data(), truncated: false, totalBytes: 0)
    }

    private static func readCapturedOutput(at url: URL) throws -> CapturedOutput {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard byteCount > UInt64(maximumCapturedBytes) else {
            return CapturedOutput(
                data: try Data(contentsOf: url, options: [.mappedIfSafe]),
                truncated: false,
                totalBytes: byteCount
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: capturedEdgeBytes) ?? Data()
        try handle.seek(toOffset: byteCount - UInt64(capturedEdgeBytes))
        let tail = try handle.read(upToCount: capturedEdgeBytes) ?? Data()
        let omitted = byteCount - UInt64(head.count + tail.count)
        let marker = Data("\n... [SparkleReleaseKit omitted \(omitted) output bytes] ...\n".utf8)
        return CapturedOutput(
            data: head + marker + tail,
            truncated: true,
            totalBytes: byteCount
        )
    }

    private static func signal(process: Process, signal: Int32, processGroup: Bool) {
        let pid = process.processIdentifier
        if processGroup {
            _ = kill(-pid, signal)
        } else {
            _ = kill(pid, signal)
        }
    }
}
