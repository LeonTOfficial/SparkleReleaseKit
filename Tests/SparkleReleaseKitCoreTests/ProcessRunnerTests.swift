import Darwin
import Foundation
import Testing
@testable import SparkleReleaseKitCore

@Suite("Process execution")
struct ProcessRunnerTests {
    @Test("Captures verbose stdout and stderr without blocking", .timeLimit(.minutes(1)))
    func capturesLargeOutput() throws {
        let command = "i=0; while [ $i -lt 12000 ]; do echo output-$i; echo error-$i >&2; i=$((i+1)); done"

        let result = try ProcessRunner().run("/bin/sh", arguments: ["-c", command])

        #expect(result.status == 0)
        #expect(result.standardOutput.contains("output-11999"))
        #expect(result.standardError.contains("error-11999"))
    }

    @Test("Bounds extremely large captured output while preserving both ends", .timeLimit(.minutes(1)))
    func boundsExtremeOutput() throws {
        let command = "printf 'start\\n'; head -c 10000000 /dev/zero | tr '\\0' x; printf '\\nend\\n'"

        let result = try ProcessRunner().run("/bin/sh", arguments: ["-c", command])

        #expect(result.status == 0)
        #expect(result.standardOutput.hasPrefix("start"))
        #expect(result.standardOutput.hasSuffix("end"))
        #expect(result.standardOutput.contains("SparkleReleaseKit omitted"))
        #expect(result.standardOutput.utf8.count < 8_500_000)
        #expect(result.standardOutputTruncated)
        #expect(result.standardOutputBytes > 10_000_000)
    }

    @Test("Terminates a process that exceeds its timeout", .timeLimit(.minutes(1)))
    func timesOut() throws {
        let started = Date()

        let result = try ProcessRunner().run(
            "/bin/sleep",
            arguments: ["10"],
            timeout: 0.1
        )

        #expect(result.timedOut)
        #expect(result.status == 124)
        #expect(result.terminationReason == .timeout)
        #expect(result.terminationSignal == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("Distinguishes signal termination from an exit status")
    func reportsSignalTermination() throws {
        let result = try ProcessRunner().run(
            "/bin/sh",
            arguments: ["-c", "kill -TERM $$"]
        )

        #expect(!result.timedOut)
        #expect(result.terminationReason == .signal)
        #expect(result.terminationSignal == SIGTERM)
    }

    @Test("Supports a configurable retained-output limit")
    func configurableOutputLimit() throws {
        let result = try ProcessRunner().run(
            "/usr/bin/printf",
            arguments: [String(repeating: "x", count: 20_000)],
            maximumCapturedBytes: 2_048
        )

        #expect(result.status == 0)
        #expect(result.standardOutputTruncated)
        #expect(result.standardOutputBytes == 20_000)
        #expect(result.standardOutput.utf8.count < 2_200)
    }

    @Test("Uses an explicit minimal environment without ambient secrets")
    func minimalEnvironment() throws {
        setenv("SRK_PROCESS_TEST_SECRET", "must-not-be-inherited", 1)
        defer { unsetenv("SRK_PROCESS_TEST_SECRET") }

        let result = try ProcessRunner().run(
            "/usr/bin/env",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            inheritEnvironment: false
        )

        #expect(result.status == 0)
        #expect(result.standardOutput.contains("PATH=/usr/bin:/bin"))
        #expect(!result.standardOutput.contains("SRK_PROCESS_TEST_SECRET"))
        #expect(!result.standardOutput.contains("must-not-be-inherited"))
    }

    @Test("Passes arguments literally without shell interpretation")
    func literalArguments() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-Argument-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: marker) }
        let argument = "safe;/usr/bin/touch \(marker.path)"

        let result = try ProcessRunner().run(
            "/usr/bin/printf",
            arguments: ["%s", argument]
        )

        #expect(result.standardOutput == argument)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Terminates descendants in the process group after a timeout")
    func terminatesProcessTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SparkleReleaseKit-ProcessTree-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let childPID = root.appendingPathComponent("child.pid")
        let script =
            "sleep 30 & child=$!; printf '%s' \"$child\" > "
            + "\"\(childPID.path)\"; wait \"$child\""

        let result = try ProcessRunner().run(
            "/bin/sh",
            arguments: ["-c", script],
            timeout: 0.2
        )
        let pidText = try String(
            contentsOf: childPID,
            encoding: .utf8
        )
        let pid = try #require(Int32(pidText))

        #expect(result.terminationReason == .timeout)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
