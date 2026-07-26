import Foundation
import SparkleReleaseKitCLISupport
import Testing

@Suite("Guided terminal")
struct GuidedTerminalTests {
    @Test("Write confirmation defaults to No")
    func confirmationDefaultsToNo() {
        let fixture = terminalFixture(inputs: [""])

        let result = fixture.terminal.confirm("Apply these changes?")

        #expect(!result)
        #expect(fixture.output.value.contains("[y/N]"))
    }

    @Test("Selection supports Use, Edit, and Cancel")
    func selectionDecisions() {
        let use = terminalFixture(inputs: ["u"])
        #expect(use.terminal.reviewDecision() == .use)

        let edit = terminalFixture(inputs: ["e"])
        #expect(edit.terminal.reviewDecision() == .edit)

        let cancel = terminalFixture(inputs: ["q"])
        #expect(cancel.terminal.reviewDecision() == .cancel)
    }

    @Test("Ambiguous choices use numbered selection and permit cancellation")
    func numberedChoices() {
        let selected = terminalFixture(inputs: ["2"])
        #expect(
            selected.terminal.chooseNumbered(
                "Choose a scheme",
                choices: ["Stable", "Beta"]
            ) == "Beta"
        )

        let cancelled = terminalFixture(inputs: ["q"])
        #expect(
            cancelled.terminal.chooseNumbered(
                "Choose a target",
                choices: ["App", "Helper"]
            ) == nil
        )
    }

    @Test("Plain progress output has stable lines and no terminal controls")
    func plainProgressIsStable() throws {
        let fixture = terminalFixture(inputs: [], stdoutIsTTY: false)
        let reporter = TerminalProgressReporter(
            io: fixture.io,
            plainHeartbeatInterval: 0.01
        )

        _ = try reporter.run(
            step: 1,
            total: 2,
            title: "Running validation",
            operation: "xcodebuild"
        ) {
            Thread.sleep(forTimeInterval: 0.04)
            return true
        }

        #expect(fixture.output.value.contains("[1/2] Running validation..."))
        #expect(fixture.output.value.contains("Still working: xcodebuild"))
        #expect(fixture.output.value.contains("[PASS] Completed"))
        #expect(!fixture.output.value.contains("\u{001B}"))
        #expect(!fixture.output.value.contains("\r"))
    }

    @Test("TTY progress uses a heartbeat and sanitizes failures")
    func ttyProgressAndFailure() {
        struct SyntheticError: LocalizedError {
            var errorDescription: String? {
                "failed\u{001B}[31m\u{202E}" + String(repeating: "x", count: 3_000)
            }
        }

        let fixture = terminalFixture(inputs: [], stdoutIsTTY: true)
        let reporter = TerminalProgressReporter(
            io: fixture.io,
            spinnerInterval: 0.01
        )

        #expect(throws: SyntheticError.self) {
            try reporter.run(
                step: 1,
                total: 1,
                title: "Running command",
                operation: "xcodebuild"
            ) {
                Thread.sleep(forTimeInterval: 0.04)
                throw SyntheticError()
            }
        }
        #expect(fixture.output.value.contains("\r"))
        #expect(fixture.output.value.contains("[FAIL]"))
        #expect(fixture.output.value.contains("\\u{1B}"))
        #expect(fixture.output.value.contains("\\u{202E}"))
        #expect(fixture.output.value.contains("[truncated]"))
    }

    @Test("NO_COLOR disables color capability")
    func noColorIsHonored() {
        let output = LockedText()
        let io = TerminalIO(
            stdinIsTTY: true,
            stdoutIsTTY: true,
            environment: ["NO_COLOR": "1"],
            read: { nil },
            write: { output.append($0) }
        )

        #expect(!io.colorEnabled)
    }

    private func terminalFixture(
        inputs: [String],
        stdoutIsTTY: Bool = false
    ) -> (terminal: GuidedTerminal, io: TerminalIO, output: LockedText) {
        let input = LockedInput(inputs)
        let output = LockedText()
        let io = TerminalIO(
            stdinIsTTY: true,
            stdoutIsTTY: stdoutIsTTY,
            environment: [:],
            read: { input.next() },
            write: { output.append($0) }
        )
        return (GuidedTerminal(io: io), io, output)
    }
}

private final class LockedInput: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage += value
        lock.unlock()
    }
}
