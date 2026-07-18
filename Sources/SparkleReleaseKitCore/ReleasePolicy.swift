import Foundation

public enum ReleasePolicyError: LocalizedError, Equatable {
    case conflictingMode(String)
    case invalidTeamIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .conflictingMode(let detail):
            "The release policy is inconsistent: \(detail)"
        case .invalidTeamIdentifier(let value):
            "The expected Apple Team ID must contain exactly 10 uppercase letters or digits: \(value)"
        }
    }
}

public struct ReleasePolicyOverrides: Equatable, Sendable {
    public var releaseMode: ReleaseMode?
    public var requireSparkleSignature: Bool
    public var requireDeveloperID: Bool
    public var requireNotarization: Bool
    public var allowAdHocSigning: Bool

    public init(
        releaseMode: ReleaseMode? = nil,
        requireSparkleSignature: Bool = false,
        requireDeveloperID: Bool = false,
        requireNotarization: Bool = false,
        allowAdHocSigning: Bool = false
    ) {
        self.releaseMode = releaseMode
        self.requireSparkleSignature = requireSparkleSignature
        self.requireDeveloperID = requireDeveloperID
        self.requireNotarization = requireNotarization
        self.allowAdHocSigning = allowAdHocSigning
    }
}

public struct ReleaseVerificationPolicy: Equatable, Sendable {
    public var releaseMode: ReleaseMode
    public var requireSparkleSignature: Bool
    public var requireDeveloperID: Bool
    public var requireNotarization: Bool
    public var allowAdHocSigning: Bool
    public var expectedArchitectures: [CPUArchitecture]
    public var expectedTeamIdentifier: String?

    public static let free = ReleaseVerificationPolicy(
        releaseMode: .free,
        requireSparkleSignature: true,
        requireDeveloperID: false,
        requireNotarization: false,
        allowAdHocSigning: true,
        expectedArchitectures: [],
        expectedTeamIdentifier: nil
    )

    public init(
        releaseMode: ReleaseMode,
        requireSparkleSignature: Bool,
        requireDeveloperID: Bool,
        requireNotarization: Bool,
        allowAdHocSigning: Bool,
        expectedArchitectures: [CPUArchitecture],
        expectedTeamIdentifier: String?
    ) {
        self.releaseMode = releaseMode
        self.requireSparkleSignature = requireSparkleSignature
        self.requireDeveloperID = requireDeveloperID
        self.requireNotarization = requireNotarization
        self.allowAdHocSigning = allowAdHocSigning
        self.expectedArchitectures = expectedArchitectures.sorted()
        self.expectedTeamIdentifier = expectedTeamIdentifier
    }

    public init(
        distribution: SparkleKitConfiguration.Distribution,
        overrides: ReleasePolicyOverrides = .init()
    ) throws {
        let mode = overrides.releaseMode ?? distribution.releaseMode
        let defaults = Self.defaults(for: mode)
        let useConfigurationValues = overrides.releaseMode == nil || overrides.releaseMode == distribution.releaseMode
        releaseMode = mode
        requireSparkleSignature =
            overrides.requireSparkleSignature
            || (useConfigurationValues ? distribution.requireSparkleSignature : defaults.requireSparkleSignature)
        requireDeveloperID =
            overrides.requireDeveloperID
            || (useConfigurationValues ? distribution.requireDeveloperID : defaults.requireDeveloperID)
        requireNotarization =
            overrides.requireNotarization
            || (useConfigurationValues ? distribution.requireNotarization : defaults.requireNotarization)
        allowAdHocSigning =
            overrides.allowAdHocSigning
            || (useConfigurationValues ? distribution.allowAdHocSigning : defaults.allowAdHocSigning)
        expectedArchitectures = Array(Set(distribution.expectedArchitectures)).sorted()
        expectedTeamIdentifier = distribution.expectedTeamIdentifier
        try validate()
    }

    public func validate() throws {
        if !requireSparkleSignature {
            throw ReleasePolicyError.conflictingMode("Sparkle EdDSA authentication cannot be disabled")
        }
        if requireNotarization && !requireDeveloperID {
            throw ReleasePolicyError.conflictingMode("notarization requires Developer ID signing")
        }
        if requireDeveloperID && allowAdHocSigning {
            throw ReleasePolicyError.conflictingMode("Developer ID requirements cannot allow ad-hoc signing")
        }
        if releaseMode == .free && (requireDeveloperID || requireNotarization || !allowAdHocSigning) {
            throw ReleasePolicyError.conflictingMode(
                "free mode requires EdDSA, allows ad-hoc signing, and cannot require Developer ID or notarization"
            )
        }
        if releaseMode == .developerID && (!requireDeveloperID || !requireNotarization || allowAdHocSigning) {
            throw ReleasePolicyError.conflictingMode(
                "developer-id mode requires Developer ID and notarization and cannot allow ad-hoc signing"
            )
        }
        if let expectedTeamIdentifier,
            expectedTeamIdentifier.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) == nil
        {
            throw ReleasePolicyError.invalidTeamIdentifier(expectedTeamIdentifier)
        }
    }

    private static func defaults(for mode: ReleaseMode) -> Self {
        switch mode {
        case .free:
            .free
        case .developerID:
            .init(
                releaseMode: .developerID,
                requireSparkleSignature: true,
                requireDeveloperID: true,
                requireNotarization: true,
                allowAdHocSigning: false,
                expectedArchitectures: [],
                expectedTeamIdentifier: nil
            )
        case .auto:
            .init(
                releaseMode: .auto,
                requireSparkleSignature: true,
                requireDeveloperID: false,
                requireNotarization: false,
                allowAdHocSigning: true,
                expectedArchitectures: [],
                expectedTeamIdentifier: nil
            )
        }
    }
}
