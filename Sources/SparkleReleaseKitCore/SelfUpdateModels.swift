import Foundation

public enum SelfUpdateChannel: String, Codable, Sendable {
    case stable
    case beta
}

public struct SelfUpdateManifest: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public var name: String
        public var url: String
        public var bytes: Int64
        public var sha256: String
        public var executablePath: String
        public var resourceBundlePath: String

        public init(
            name: String,
            url: String,
            bytes: Int64,
            sha256: String,
            executablePath: String = "SparkleReleaseKit/sparklekit",
            resourceBundlePath: String =
                "SparkleReleaseKit/SparkleReleaseKit_SparkleReleaseKitCore.bundle"
        ) {
            self.name = name
            self.url = url
            self.bytes = bytes
            self.sha256 = sha256
            self.executablePath = executablePath
            self.resourceBundlePath = resourceBundlePath
        }
    }

    public var schemaVersion: Int
    public var version: String
    public var channel: SelfUpdateChannel
    public var minimumMacOS: String
    public var sourceCommit: String
    public var releaseNotesURL: String
    public var releaseNotes: [String]
    public var asset: Asset

    public init(
        schemaVersion: Int = 1,
        version: String,
        channel: SelfUpdateChannel = .stable,
        minimumMacOS: String = "13.0",
        sourceCommit: String,
        releaseNotesURL: String,
        releaseNotes: [String],
        asset: Asset
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.channel = channel
        self.minimumMacOS = minimumMacOS
        self.sourceCommit = sourceCommit
        self.releaseNotesURL = releaseNotesURL
        self.releaseNotes = releaseNotes
        self.asset = asset
    }
}

public struct SelfUpdateCheckResult: Codable, Equatable, Sendable {
    public var installedVersion: String
    public var availableVersion: String
    public var updateAvailable: Bool
    public var channel: SelfUpdateChannel
    public var releaseNotes: [String]
    public var releaseNotesURL: String
    public var sourceCommit: String

    public init(
        installedVersion: String,
        availableVersion: String,
        updateAvailable: Bool,
        channel: SelfUpdateChannel,
        releaseNotes: [String],
        releaseNotesURL: String,
        sourceCommit: String
    ) {
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.updateAvailable = updateAvailable
        self.channel = channel
        self.releaseNotes = releaseNotes
        self.releaseNotesURL = releaseNotesURL
        self.sourceCommit = sourceCommit
    }
}

public struct SelfUpdateInstallResult: Codable, Equatable, Sendable {
    public var previousVersion: String
    public var installedVersion: String
    public var installationPath: String
    public var backupPath: String

    public init(
        previousVersion: String,
        installedVersion: String,
        installationPath: String,
        backupPath: String
    ) {
        self.previousVersion = previousVersion
        self.installedVersion = installedVersion
        self.installationPath = installationPath
        self.backupPath = backupPath
    }
}

public struct SelfUpdateRollbackResult: Codable, Equatable, Sendable {
    public var restoredVersion: String
    public var replacedVersion: String
    public var installationPath: String

    public init(
        restoredVersion: String,
        replacedVersion: String,
        installationPath: String
    ) {
        self.restoredVersion = restoredVersion
        self.replacedVersion = replacedVersion
        self.installationPath = installationPath
    }
}

public enum SelfUpdateError: LocalizedError, Equatable {
    case invalidInstalledVersion
    case unsupportedManifest
    case malformedManifest(String)
    case invalidManifestSignature
    case invalidTrustRoot
    case unsafeURL
    case networkFailure
    case responseTooLarge
    case timeout
    case unsupportedChannel(String)
    case noUpdateAvailable
    case incompatibleMacOS(required: String)
    case downgradeRefused(installed: String, requested: String)
    case assetSizeMismatch
    case assetDigestMismatch
    case unsafeArchive
    case invalidDownloadedExecutable
    case unsafeInstallationPath
    case installationNotWritable
    case updateAlreadyRunning
    case installationFailed
    case missingRollback
    case invalidRollback

    public var errorDescription: String? {
        switch self {
        case .invalidInstalledVersion:
            "The installed SparkleReleaseKit version is not a valid semantic version."
        case .unsupportedManifest:
            "The SparkleReleaseKit update manifest schema is not supported."
        case .malformedManifest(let detail):
            "The SparkleReleaseKit update manifest is invalid: \(detail)"
        case .invalidManifestSignature:
            "The SparkleReleaseKit update manifest signature is invalid."
        case .invalidTrustRoot:
            "The embedded SparkleReleaseKit update trust root is invalid."
        case .unsafeURL:
            "SparkleReleaseKit updates require credential-free HTTPS URLs."
        case .networkFailure:
            "The SparkleReleaseKit update server could not be reached."
        case .responseTooLarge:
            "The SparkleReleaseKit update response exceeds its safety limit."
        case .timeout:
            "The SparkleReleaseKit update request exceeded its timeout."
        case .unsupportedChannel(let channel):
            "The SparkleReleaseKit update channel '\(channel)' is not configured."
        case .noUpdateAvailable:
            "No newer stable SparkleReleaseKit version is available."
        case .incompatibleMacOS(let required):
            "This SparkleReleaseKit update requires macOS \(required) or later."
        case .downgradeRefused(let installed, let requested):
            "Refusing to replace SparkleReleaseKit \(installed) with older version \(requested)."
        case .assetSizeMismatch:
            "The downloaded SparkleReleaseKit package size does not match the signed manifest."
        case .assetDigestMismatch:
            "The downloaded SparkleReleaseKit package SHA-256 does not match the signed manifest."
        case .unsafeArchive:
            "The downloaded SparkleReleaseKit package contains an unsafe or unexpected archive layout."
        case .invalidDownloadedExecutable:
            "The downloaded SparkleReleaseKit executable does not have a valid strict code signature."
        case .unsafeInstallationPath:
            "The SparkleReleaseKit installation path is unsafe or unsupported."
        case .installationNotWritable:
            "The SparkleReleaseKit installation directory is not writable."
        case .updateAlreadyRunning:
            "Another SparkleReleaseKit update transaction is already running."
        case .installationFailed:
            "The SparkleReleaseKit update transaction failed and was rolled back."
        case .missingRollback:
            "No previous SparkleReleaseKit installation is available for rollback."
        case .invalidRollback:
            "The saved SparkleReleaseKit rollback executable failed integrity verification."
        }
    }
}
