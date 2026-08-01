import Darwin
import Foundation
import SparkleReleaseKitCore

do {
    try SparkleKitCLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    let mapped = error as? SparkleKitExitCodeError
    if mapped?.suppressTextOutput != true {
        let message = TerminalSanitizer.indented(
            error.localizedDescription,
            prefix: "Error: "
        )
        FileHandle.standardError.write(Data("\n\(message)\n".utf8))
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
    } else if let updateError = error as? SelfUpdateError {
        switch updateError {
        case .networkFailure, .responseTooLarge, .timeout:
            code = 1
        case .noUpdateAvailable:
            code = 2
        default:
            code = 78
        }
    } else if error is IntegrationError
        || error is ReleasePreparationError
        || error is GenerateAppcastTrustError
        || error is UserConfigurationError
        || error is XcodeBuildValidationError
    {
        code = 78
    } else {
        code = 1
    }
    exit(code)
}
