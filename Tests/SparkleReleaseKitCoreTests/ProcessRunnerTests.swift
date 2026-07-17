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
}
