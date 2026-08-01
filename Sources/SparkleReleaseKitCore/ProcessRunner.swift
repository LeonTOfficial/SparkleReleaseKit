import Darwin
import Foundation

public enum ProcessRunnerError: LocalizedError, Equatable {
    case invalidTimeout
    case invalidOutputLimit
    case couldNotTerminate(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "Process timeout must be a finite value greater than zero."
        case .invalidOutputLimit:
            "Process output limit must be between 1 byte and 64 MiB."
        case .couldNotTerminate(let pid):
            "Process \(pid) did not stop after the timeout and forced termination."
        }
    }
}

public enum ProcessTerminationReason: String, Codable, Equatable, Sendable {
    case exit
    case signal
    case timeout
}

public struct ProcessResult: Sendable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String
    public var timedOut: Bool
    public var terminationReason: ProcessTerminationReason
    public var terminationSignal: Int32?
    public var standardOutputTruncated: Bool
    public var standardErrorTruncated: Bool
    public var standardOutputBytes: UInt64
    public var standardErrorBytes: UInt64

    public init(
        status: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool = false,
        terminationReason: ProcessTerminationReason? = nil,
        terminationSignal: Int32? = nil,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false,
        standardOutputBytes: UInt64 = 0,
        standardErrorBytes: UInt64 = 0
    ) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.terminationReason =
            terminationReason ?? (timedOut ? .timeout : .exit)
        self.terminationSignal = terminationSignal
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
        self.standardOutputBytes = standardOutputBytes
        self.standardErrorBytes = standardErrorBytes
    }
}

public struct ProcessRunner: Sendable {
    public static let defaultMaximumCapturedBytes = 8 * 1_024 * 1_024
    private static let largestMaximumCapturedBytes = 64 * 1_024 * 1_024
    private static let terminationGracePeriod: TimeInterval = 2

    public init() {}

    @discardableResult
    public func run(
        _ executable: String,
        arguments: [String],
        directory: URL? = nil,
        environment: [String: String]? = nil,
        inheritEnvironment: Bool = true,
        timeout: TimeInterval = 300,
        maximumCapturedBytes: Int = Self.defaultMaximumCapturedBytes
    ) throws -> ProcessResult {
        guard timeout > 0, timeout.isFinite else {
            throw ProcessRunnerError.invalidTimeout
        }
        guard maximumCapturedBytes > 0,
            maximumCapturedBytes <= Self.largestMaximumCapturedBytes
        else {
            throw ProcessRunnerError.invalidOutputLimit
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
                var descendants = Self.signalTree(
                    process: process,
                    signal: SIGTERM,
                    processGroup: ownsProcessGroup
                )
                if completion.wait(timeout: .now() + Self.terminationGracePeriod) == .timedOut {
                    descendants += Self.signalTree(
                        process: process,
                        signal: SIGKILL,
                        processGroup: ownsProcessGroup
                    )
                    guard completion.wait(timeout: .now() + Self.terminationGracePeriod) == .success else {
                        throw ProcessRunnerError.couldNotTerminate(pid)
                    }
                }
                Self.finishDescendants(descendants)
            }
            try stdoutHandle.close()
            try stderrHandle.close()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw error
        }

        let stdout =
            (try? Self.readCapturedOutput(
                at: stdoutURL,
                maximumBytes: maximumCapturedBytes
            )) ?? .empty
        let stderr =
            (try? Self.readCapturedOutput(
                at: stderrURL,
                maximumBytes: maximumCapturedBytes
            )) ?? .empty
        let reason: ProcessTerminationReason
        let signal: Int32?
        if timedOut {
            reason = .timeout
            signal = nil
        } else if process.terminationReason == .uncaughtSignal {
            reason = .signal
            signal = process.terminationStatus
        } else {
            reason = .exit
            signal = nil
        }
        return ProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            standardOutput: String(decoding: stdout.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: String(decoding: stderr.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut,
            terminationReason: reason,
            terminationSignal: signal,
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

    private static func readCapturedOutput(
        at url: URL,
        maximumBytes: Int
    ) throws -> CapturedOutput {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard byteCount > UInt64(maximumBytes) else {
            return CapturedOutput(
                data: try Data(contentsOf: url, options: [.mappedIfSafe]),
                truncated: false,
                totalBytes: byteCount
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let capturedEdgeBytes = max(1, maximumBytes / 2)
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

    private static func signalTree(
        process: Process,
        signal: Int32,
        processGroup: Bool
    ) -> [pid_t] {
        let pid = process.processIdentifier
        let descendants = descendantPIDs(of: pid)
        for child in descendants.reversed() {
            _ = kill(child, signal)
        }
        if processGroup {
            _ = kill(-pid, signal)
        } else {
            _ = kill(pid, signal)
        }
        return descendants
    }

    private static func descendantPIDs(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending = [root]
        var seen = Set([root])
        while let parent = pending.popLast() {
            for child in directChildPIDs(of: parent)
                where child > 0 && seen.insert(child).inserted
            {
                result.append(child)
                pending.append(child)
            }
        }
        return result
    }

    private static func directChildPIDs(of parent: pid_t) -> [pid_t] {
        var capacity = 32
        while capacity <= 4_096 {
            var children = [pid_t](repeating: 0, count: capacity)
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(
                    parent,
                    $0.baseAddress,
                    Int32($0.count)
                )
            }
            guard count >= 0 else { return [] }
            if count < capacity {
                return Array(children.prefix(Int(count)))
                    .filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    private static func finishDescendants(_ descendants: [pid_t]) {
        let unique = Set(descendants)
        guard !unique.isEmpty else { return }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            let alive = unique.filter { kill($0, 0) == 0 || errno != ESRCH }
            if alive.isEmpty { return }
            usleep(10_000)
        }
        for pid in unique {
            _ = kill(pid, SIGKILL)
        }
    }
}
