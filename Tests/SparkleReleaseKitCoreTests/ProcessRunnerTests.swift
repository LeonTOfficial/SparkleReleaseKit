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
    }
}
