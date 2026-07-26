import Foundation
import SparkleReleaseKitCore

public enum GuidedReviewDecision: Equatable, Sendable {
    case use
    case edit
    case cancel
}

public final class TerminalIO: @unchecked Sendable {
    private let readHandler: () -> String?
    private let writeHandler: (String) -> Void
    private let lock = NSLock()

    public let stdinIsTTY: Bool
    public let stdoutIsTTY: Bool
    public let colorEnabled: Bool

    public init(
        stdinIsTTY: Bool,
        stdoutIsTTY: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        read: @escaping () -> String?,
        write: @escaping (String) -> Void
    ) {
        self.stdinIsTTY = stdinIsTTY
        self.stdoutIsTTY = stdoutIsTTY
        colorEnabled = stdoutIsTTY && environment["NO_COLOR"] == nil
        readHandler = read
        writeHandler = write
    }

    public static func standard() -> TerminalIO {
        TerminalIO(
            stdinIsTTY: isatty(STDIN_FILENO) != 0,
            stdoutIsTTY: isatty(STDOUT_FILENO) != 0,
            read: { Swift.readLine() },
            write: { value in
                FileHandle.standardOutput.write(Data(value.utf8))
            }
        )
    }

    public func readLine() -> String? {
        readHandler()
    }

    public func writeRaw(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        writeHandler(value)
    }

    public func writeLine(_ value: String = "") {
        writeRaw(TerminalSanitizer.text(value, preserveNewlines: false) + "\n")
    }

    public func writeSafeText(_ value: String) {
        writeRaw(TerminalSanitizer.text(value))
    }
}

public struct GuidedTerminal {
    public let io: TerminalIO

    public init(io: TerminalIO) {
        self.io = io
    }

    public func prompt(
        _ label: String,
        defaultValue: String = "",
        showDefault: Bool = true
    ) -> String {
        let safeLabel = TerminalSanitizer.text(label, preserveNewlines: false)
        let safeDefault = TerminalSanitizer.text(defaultValue, preserveNewlines: false)
        let suffix =
            showDefault && !safeDefault.isEmpty
            ? " [\(safeDefault)]"
            : ""
        io.writeRaw("\(safeLabel)\(suffix): ")
        guard let value = io.readLine() else { return defaultValue }
        return value.isEmpty ? defaultValue : value
    }

    public func confirm(_ label: String, defaultValue: Bool = false) -> Bool {
        let fallback = defaultValue ? "Y/n" : "y/N"
        let value = prompt("\(label) [\(fallback)]")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.isEmpty { return defaultValue }
        return ["y", "yes", "j", "ja"].contains(value)
    }

    public func reviewDecision() -> GuidedReviewDecision {
        while true {
            io.writeLine()
            io.writeLine("      Use this selection?")
            io.writeLine("      [U] Use it")
            io.writeLine("      [E] Edit selection")
            io.writeLine("      [Q] Cancel")
            let value = prompt("      Choice", defaultValue: "U")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch value {
            case "", "u", "use", "y", "yes", "j", "ja":
                return .use
            case "e", "edit":
                return .edit
            case "q", "quit", "cancel", "c":
                return .cancel
            default:
                io.writeLine("      Enter U, E, or Q.")
            }
        }
    }

    public func chooseNumbered(
        _ label: String,
        choices: [String]
    ) -> String? {
        precondition(!choices.isEmpty)
        io.writeLine("      \(label)")
        for (index, choice) in choices.enumerated() {
            io.writeLine("      [\(index + 1)] \(choice)")
        }
        io.writeLine("      [Q] Cancel")
        while true {
            let value = prompt("      Selection")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if ["q", "quit", "cancel", "c"].contains(value.lowercased()) {
                return nil
            }
            if let number = Int(value), choices.indices.contains(number - 1) {
                return choices[number - 1]
            }
            io.writeLine("      Enter a number from 1 to \(choices.count), or Q.")
        }
    }
}

public struct ProgressToken: Sendable {
    fileprivate let step: Int
    fileprivate let total: Int
    fileprivate let title: String
    fileprivate let startedAt: Date
}

public final class TerminalProgressReporter: @unchecked Sendable {
    private let io: TerminalIO
    private let now: () -> Date
    private let spinnerInterval: TimeInterval
    private let plainHeartbeatInterval: TimeInterval

    public init(
        io: TerminalIO,
        spinnerInterval: TimeInterval = 0.12,
        plainHeartbeatInterval: TimeInterval = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.io = io
        self.spinnerInterval = max(0.01, spinnerInterval)
        self.plainHeartbeatInterval = max(0.01, plainHeartbeatInterval)
        self.now = now
    }

    @discardableResult
    public func begin(step: Int, total: Int, title: String) -> ProgressToken {
        let safeTitle = bounded(title)
        io.writeLine("[\(step)/\(total)] \(safeTitle)...")
        return ProgressToken(
            step: step,
            total: total,
            title: safeTitle,
            startedAt: now()
        )
    }

    public func detail(_ value: String) {
        io.writeLine("      \(bounded(value))")
    }

    public func complete(_ token: ProgressToken, message: String? = nil) {
        let elapsed = formatElapsed(now().timeIntervalSince(token.startedAt))
        let suffix = message.map { "\(bounded($0)) in \(elapsed)" } ?? "Completed in \(elapsed)"
        io.writeLine("      [PASS] \(suffix)")
        io.writeLine()
    }

    public func warn(_ token: ProgressToken, message: String) {
        let elapsed = formatElapsed(now().timeIntervalSince(token.startedAt))
        io.writeLine("      [WARN] \(bounded(message)) (\(elapsed))")
        io.writeLine()
    }

    public func fail(_ token: ProgressToken, error: Error) {
        fail(token, message: error.localizedDescription)
    }

    public func fail(_ token: ProgressToken, message: String) {
        let elapsed = formatElapsed(now().timeIntervalSince(token.startedAt))
        io.writeLine("      [FAIL] \(bounded(message)) (\(elapsed))")
        io.writeLine()
    }

    public func skipped(_ token: ProgressToken, reason: String) {
        io.writeLine("      [SKIP] \(bounded(reason))")
        io.writeLine()
    }

    public func run<T>(
        step: Int,
        total: Int,
        title: String,
        operation: String,
        body: () throws -> T
    ) throws -> T {
        let token = begin(step: step, total: total, title: title)
        let heartbeat = Heartbeat(
            io: io,
            operation: bounded(operation),
            startedAt: token.startedAt,
            now: now,
            spinnerInterval: spinnerInterval,
            plainInterval: plainHeartbeatInterval
        )
        heartbeat.start()
        do {
            let result = try body()
            heartbeat.stop()
            complete(token)
            return result
        } catch {
            heartbeat.stop()
            fail(token, error: error)
            throw error
        }
    }

    public func withHeartbeat<T>(
        operation: String,
        body: () throws -> T
    ) throws -> T {
        let heartbeat = Heartbeat(
            io: io,
            operation: bounded(operation),
            startedAt: now(),
            now: now,
            spinnerInterval: spinnerInterval,
            plainInterval: plainHeartbeatInterval
        )
        heartbeat.start()
        defer { heartbeat.stop() }
        return try body()
    }

    private func bounded(_ value: String, maximumCharacters: Int = 2_048) -> String {
        let safe = TerminalSanitizer.text(value, preserveNewlines: false)
        guard safe.count > maximumCharacters else { return safe }
        return String(safe.prefix(maximumCharacters)) + "... [truncated]"
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", max(0, interval))
    }

    private final class Heartbeat: @unchecked Sendable {
        private let io: TerminalIO
        private let operation: String
        private let startedAt: Date
        private let now: () -> Date
        private let spinnerInterval: TimeInterval
        private let plainInterval: TimeInterval
        private let queue = DispatchQueue(label: "SparkleReleaseKit.terminal-heartbeat")
        private var timer: DispatchSourceTimer?
        private var frame = 0

        init(
            io: TerminalIO,
            operation: String,
            startedAt: Date,
            now: @escaping () -> Date,
            spinnerInterval: TimeInterval,
            plainInterval: TimeInterval
        ) {
            self.io = io
            self.operation = operation
            self.startedAt = startedAt
            self.now = now
            self.spinnerInterval = spinnerInterval
            self.plainInterval = plainInterval
        }

        func start() {
            queue.sync {
                let interval = io.stdoutIsTTY ? spinnerInterval : plainInterval
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + interval, repeating: interval)
                timer.setEventHandler { [weak self] in
                    self?.tick()
                }
                self.timer = timer
                timer.resume()
            }
        }

        func stop() {
            let shouldClear = queue.sync {
                timer?.setEventHandler {}
                timer?.cancel()
                timer = nil
                return io.stdoutIsTTY && frame > 0
            }
            if shouldClear {
                io.writeRaw("\r" + String(repeating: " ", count: 96) + "\r")
            }
        }

        private func tick() {
            let elapsed = String(
                format: "%.1fs",
                max(0, now().timeIntervalSince(startedAt))
            )
            if io.stdoutIsTTY {
                let frames = ["|", "/", "-", "\\"]
                let value = frames[frame % frames.count]
                frame += 1
                io.writeRaw("\r      \(value) \(operation) (\(elapsed))")
            } else {
                io.writeLine("      Still working: \(operation) (\(elapsed))")
            }
        }
    }
}
