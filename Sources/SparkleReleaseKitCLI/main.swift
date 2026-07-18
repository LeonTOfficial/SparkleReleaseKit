import Darwin
import Foundation
import SparkleReleaseKitCore

do {
    try SparkleKitCLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    let mapped = error as? SparkleKitExitCodeError
    if mapped?.suppressTextOutput != true {
        FileHandle.standardError.write(Data("\nError: \(error.localizedDescription)\n".utf8))
    }
    let code: Int32
    if let mapped {
        code = mapped.exitCode
    } else if error is ConfigurationError || error is ReleasePolicyError {
        code = 65
    } else if error is ProjectDetectionError {
        code = 66
    } else if error is UpdateSignatureVerificationError {
        code = 2
    } else if error is IntegrationError || error is ReleasePreparationError || error is XcodeBuildValidationError {
        code = 78
    } else {
        code = 1
    }
    exit(code)
}
