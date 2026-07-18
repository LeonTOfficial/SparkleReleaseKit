import Foundation

public struct SparkleKitConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let supportedSparkleVersion = "2.9.4"
    public static let schemaURL = "https://leontofficial.github.io/SparkleReleaseKit/schema/sparklekit.schema.json"

    public var schema: String
    public var schemaVersion: Int
    public var app: App
    public var project: Project
    public var github: GitHub
    public var updates: Updates
    public var distribution: Distribution

    public init(
        schema: String = Self.schemaURL,
        schemaVersion: Int = Self.currentSchemaVersion,
        app: App,
        project: Project,
        github: GitHub,
        updates: Updates,
        distribution: Distribution = .init()
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.app = app
        self.project = project
        self.github = github
        self.updates = updates
        self.distribution = distribution
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case schemaVersion, app, project, github, updates, distribution
    }

    public struct App: Codable, Equatable, Sendable {
        public var name: String
        public var bundleIdentifier: String
        public var minimumMacOS: String
        public var style: AppStyle

        public init(name: String, bundleIdentifier: String, minimumMacOS: String = "13.0", style: AppStyle) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.minimumMacOS = minimumMacOS
            self.style = style
        }
    }

    public struct Project: Codable, Equatable, Sendable {
        public var container: String
        public var scheme: String
        public var configuration: String
        public var infoPlist: String?

        public init(container: String, scheme: String, configuration: String = "Release", infoPlist: String? = nil) {
            self.container = container
            self.scheme = scheme
            self.configuration = configuration
            self.infoPlist = infoPlist
        }
    }

    public struct GitHub: Codable, Equatable, Sendable {
        public var owner: String
        public var repository: String
        public var pagesBranch: String

        public init(owner: String, repository: String, pagesBranch: String = "gh-pages") {
            self.owner = owner
            self.repository = repository
            self.pagesBranch = pagesBranch
        }
    }

    public struct Updates: Codable, Equatable, Sendable {
        public var sparkleVersion: String
        public var feedURL: String
        public var publicEDKey: String
        public var automaticChecks: Bool
        public var automaticDownloads: Bool
        public var channel: String?

        public init(
            sparkleVersion: String = SparkleKitConfiguration.supportedSparkleVersion,
            feedURL: String,
            publicEDKey: String = "",
            automaticChecks: Bool = true,
            automaticDownloads: Bool = false,
            channel: String? = nil
        ) {
            self.sparkleVersion = sparkleVersion
            self.feedURL = feedURL
            self.publicEDKey = publicEDKey
            self.automaticChecks = automaticChecks
            self.automaticDownloads = automaticDownloads
            self.channel = channel
        }
    }

    public struct Distribution: Codable, Equatable, Sendable {
        public var installer: ArchiveFormat
        public var updateArchive: ArchiveFormat
        public var releaseMode: ReleaseMode
        public var requireSparkleSignature: Bool
        public var requireDeveloperID: Bool
        public var requireNotarization: Bool
        public var allowAdHocSigning: Bool
        public var expectedArchitectures: [CPUArchitecture]
        public var expectedTeamIdentifier: String?

        public init(
            installer: ArchiveFormat = .dmg,
            updateArchive: ArchiveFormat = .zip,
            releaseMode: ReleaseMode = .free,
            requireSparkleSignature: Bool = true,
            requireDeveloperID: Bool? = nil,
            requireNotarization: Bool? = nil,
            allowAdHocSigning: Bool? = nil,
            expectedArchitectures: [CPUArchitecture] = [.arm64, .x86_64],
            expectedTeamIdentifier: String? = nil
        ) {
            self.installer = installer
            self.updateArchive = updateArchive
            self.releaseMode = releaseMode
            self.requireSparkleSignature = requireSparkleSignature
            self.requireDeveloperID = requireDeveloperID ?? (releaseMode == .developerID)
            self.requireNotarization = requireNotarization ?? (releaseMode == .developerID)
            self.allowAdHocSigning = allowAdHocSigning ?? (releaseMode != .developerID)
            self.expectedArchitectures = expectedArchitectures
            self.expectedTeamIdentifier = expectedTeamIdentifier
        }

        private enum CodingKeys: String, CodingKey {
            case installer, updateArchive, releaseMode, requireSparkleSignature
            case requireDeveloperID, requireNotarization, allowAdHocSigning
            case expectedArchitectures, expectedTeamIdentifier
            case notarization
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            installer = try container.decode(ArchiveFormat.self, forKey: .installer)
            updateArchive = try container.decode(ArchiveFormat.self, forKey: .updateArchive)

            if let explicitMode = try container.decodeIfPresent(ReleaseMode.self, forKey: .releaseMode) {
                releaseMode = explicitMode
            } else {
                let legacy = try container.decodeIfPresent(NotarizationMode.self, forKey: .notarization) ?? .optional
                releaseMode = legacy == .required ? .developerID : .free
            }

            requireSparkleSignature = try container.decodeIfPresent(Bool.self, forKey: .requireSparkleSignature) ?? true
            requireDeveloperID =
                try container.decodeIfPresent(Bool.self, forKey: .requireDeveloperID)
                ?? (releaseMode == .developerID)
            requireNotarization =
                try container.decodeIfPresent(Bool.self, forKey: .requireNotarization)
                ?? (releaseMode == .developerID)
            allowAdHocSigning =
                try container.decodeIfPresent(Bool.self, forKey: .allowAdHocSigning)
                ?? (releaseMode != .developerID)
            expectedArchitectures = try container.decodeIfPresent([CPUArchitecture].self, forKey: .expectedArchitectures) ?? []
            expectedTeamIdentifier = try container.decodeIfPresent(String.self, forKey: .expectedTeamIdentifier)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(installer, forKey: .installer)
            try container.encode(updateArchive, forKey: .updateArchive)
            try container.encode(releaseMode, forKey: .releaseMode)
            try container.encode(requireSparkleSignature, forKey: .requireSparkleSignature)
            try container.encode(requireDeveloperID, forKey: .requireDeveloperID)
            try container.encode(requireNotarization, forKey: .requireNotarization)
            try container.encode(allowAdHocSigning, forKey: .allowAdHocSigning)
            try container.encode(expectedArchitectures, forKey: .expectedArchitectures)
            try container.encodeIfPresent(expectedTeamIdentifier, forKey: .expectedTeamIdentifier)
        }
    }
}

public enum AppStyle: String, Codable, CaseIterable, Sendable {
    case appKit
    case swiftUI
    case unknown
}

public enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    case zip
    case dmg
}

public enum ReleaseMode: String, Codable, CaseIterable, Sendable {
    case free
    case developerID = "developer-id"
    case auto
}

public enum CPUArchitecture: String, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case arm64
    case x86_64

    public static func < (lhs: CPUArchitecture, rhs: CPUArchitecture) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum NotarizationMode: String, Codable, CaseIterable, Sendable {
    case required
    case optional
    case disabled
}

public enum CodeSigningKind: String, Codable, Sendable {
    case unsigned
    case adHoc = "ad-hoc"
    case appleDevelopment = "apple-development"
    case developerID = "developer-id"
    case other
}

public struct DetectedProject: Equatable, Sendable {
    public var rootURL: URL
    public var containerURL: URL
    public var appName: String
    public var bundleIdentifier: String
    public var minimumMacOS: String
    public var scheme: String
    public var infoPlistURL: URL?
    public var style: AppStyle
    public var githubOwner: String?
    public var githubRepository: String?

    public init(
        rootURL: URL,
        containerURL: URL,
        appName: String,
        bundleIdentifier: String,
        minimumMacOS: String,
        scheme: String,
        infoPlistURL: URL?,
        style: AppStyle,
        githubOwner: String?,
        githubRepository: String?
    ) {
        self.rootURL = rootURL
        self.containerURL = containerURL
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.minimumMacOS = minimumMacOS
        self.scheme = scheme
        self.infoPlistURL = infoPlistURL
        self.style = style
        self.githubOwner = githubOwner
        self.githubRepository = githubRepository
    }
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case pass
    case warning
    case failure
}

public struct Diagnostic: Codable, Equatable, Sendable {
    public var severity: DiagnosticSeverity
    public var title: String
    public var detail: String
    public var remediation: String?

    public init(_ severity: DiagnosticSeverity, _ title: String, _ detail: String, remediation: String? = nil) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.remediation = remediation
    }
}

public struct IntegrationChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case create
        case update
        case unchanged
    }

    public var kind: Kind
    public var relativePath: String
    public var summary: String

    public init(kind: Kind, relativePath: String, summary: String) {
        self.kind = kind
        self.relativePath = relativePath
        self.summary = summary
    }
}

public struct IntegrationResult: Codable, Sendable {
    public var applied: Bool
    public var backupURL: URL?
    public var changes: [IntegrationChange]

    public init(applied: Bool, backupURL: URL?, changes: [IntegrationChange]) {
        self.applied = applied
        self.backupURL = backupURL
        self.changes = changes
    }
}

public struct ReleaseMetadata: Codable, Equatable, Sendable {
    public var appName: String
    public var bundleIdentifier: String
    public var shortVersion: String
    public var buildVersion: String

    public init(appName: String, bundleIdentifier: String, shortVersion: String, buildVersion: String) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }
}

public struct ReleaseArtifactSummary: Codable, Equatable, Sendable {
    public var archiveBytes: Int64
    public var sha256: String
    public var architectures: [CPUArchitecture]
    public var signingKind: CodeSigningKind
    public var teamIdentifier: String?
    public var hardenedRuntime: Bool
    public var gatekeeperAccepted: Bool
    public var stapledTicket: Bool
    public var requestedReleaseMode: ReleaseMode
    public var effectiveReleaseMode: ReleaseMode

    public init(
        archiveBytes: Int64,
        sha256: String,
        architectures: [CPUArchitecture],
        signingKind: CodeSigningKind,
        teamIdentifier: String?,
        hardenedRuntime: Bool,
        gatekeeperAccepted: Bool,
        stapledTicket: Bool,
        requestedReleaseMode: ReleaseMode,
        effectiveReleaseMode: ReleaseMode
    ) {
        self.archiveBytes = archiveBytes
        self.sha256 = sha256
        self.architectures = architectures
        self.signingKind = signingKind
        self.teamIdentifier = teamIdentifier
        self.hardenedRuntime = hardenedRuntime
        self.gatekeeperAccepted = gatekeeperAccepted
        self.stapledTicket = stapledTicket
        self.requestedReleaseMode = requestedReleaseMode
        self.effectiveReleaseMode = effectiveReleaseMode
    }
}

public struct ReleaseInspectionResult: Codable, Sendable {
    public var metadata: ReleaseMetadata?
    public var artifact: ReleaseArtifactSummary?
    public var diagnostics: [Diagnostic]

    public init(metadata: ReleaseMetadata?, artifact: ReleaseArtifactSummary? = nil, diagnostics: [Diagnostic]) {
        self.metadata = metadata
        self.artifact = artifact
        self.diagnostics = diagnostics
    }
}

public struct AppcastEnclosure: Codable, Equatable, Sendable {
    public var url: String
    public var version: String
    public var signature: String
    public var length: Int64

    public init(url: String, version: String, signature: String, length: Int64) {
        self.url = url
        self.version = version
        self.signature = signature
        self.length = length
    }
}

public struct AppcastValidationResult: Codable, Sendable {
    public var source: String
    public var itemCount: Int
    public var versions: [String]
    public var enclosures: [AppcastEnclosure]
    public var diagnostics: [Diagnostic]

    public init(
        source: String,
        itemCount: Int,
        versions: [String],
        enclosures: [AppcastEnclosure] = [],
        diagnostics: [Diagnostic]
    ) {
        self.source = source
        self.itemCount = itemCount
        self.versions = versions
        self.enclosures = enclosures
        self.diagnostics = diagnostics
    }
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var releaseMode: ReleaseMode
    public var appName: String
    public var bundleIdentifier: String
    public var shortVersion: String
    public var buildVersion: String
    public var archive: String
    public var archiveBytes: Int64
    public var sha256: String
    public var architectures: [CPUArchitecture]
    public var signingKind: CodeSigningKind
    public var developerIDVerified: Bool
    public var notarizationVerified: Bool
    public var sparkleSignatureVerified: Bool
    public var appcast: String

    public init(
        releaseMode: ReleaseMode,
        metadata: ReleaseMetadata,
        archive: String,
        artifact: ReleaseArtifactSummary,
        sparkleSignatureVerified: Bool,
        appcast: String
    ) {
        schemaVersion = 1
        self.releaseMode = releaseMode
        appName = metadata.appName
        bundleIdentifier = metadata.bundleIdentifier
        shortVersion = metadata.shortVersion
        buildVersion = metadata.buildVersion
        self.archive = archive
        archiveBytes = artifact.archiveBytes
        sha256 = artifact.sha256
        architectures = artifact.architectures
        signingKind = artifact.signingKind
        developerIDVerified = artifact.signingKind == .developerID
        notarizationVerified = artifact.gatekeeperAccepted && artifact.stapledTicket
        self.sparkleSignatureVerified = sparkleSignatureVerified
        self.appcast = appcast
    }
}

public struct ReleasePreparationResult: Codable, Sendable {
    public var version: String
    public var outputDirectory: URL
    public var archiveURL: URL
    public var appcastURL: URL
    public var checksumURL: URL
    public var manifestURL: URL
    public var metadata: ReleaseMetadata
    public var diagnostics: [Diagnostic]

    public init(
        version: String,
        outputDirectory: URL,
        archiveURL: URL,
        appcastURL: URL,
        checksumURL: URL,
        manifestURL: URL,
        metadata: ReleaseMetadata,
        diagnostics: [Diagnostic]
    ) {
        self.version = version
        self.outputDirectory = outputDirectory
        self.archiveURL = archiveURL
        self.appcastURL = appcastURL
        self.checksumURL = checksumURL
        self.manifestURL = manifestURL
        self.metadata = metadata
        self.diagnostics = diagnostics
    }
}
