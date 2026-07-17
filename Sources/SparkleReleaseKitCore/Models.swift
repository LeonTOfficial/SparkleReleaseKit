import Foundation

public struct SparkleKitConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
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
        public var notarization: NotarizationMode

        public init(
            installer: ArchiveFormat = .dmg,
            updateArchive: ArchiveFormat = .zip,
            notarization: NotarizationMode = .optional
        ) {
            self.installer = installer
            self.updateArchive = updateArchive
            self.notarization = notarization
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

public enum NotarizationMode: String, Codable, CaseIterable, Sendable {
    case required
    case optional
    case disabled
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

public struct ReleaseInspectionResult: Codable, Sendable {
    public var metadata: ReleaseMetadata?
    public var diagnostics: [Diagnostic]

    public init(metadata: ReleaseMetadata?, diagnostics: [Diagnostic]) {
        self.metadata = metadata
        self.diagnostics = diagnostics
    }
}

public struct AppcastValidationResult: Codable, Sendable {
    public var source: String
    public var itemCount: Int
    public var versions: [String]
    public var diagnostics: [Diagnostic]

    public init(source: String, itemCount: Int, versions: [String], diagnostics: [Diagnostic]) {
        self.source = source
        self.itemCount = itemCount
        self.versions = versions
        self.diagnostics = diagnostics
    }
}

public struct ReleasePreparationResult: Codable, Sendable {
    public var version: String
    public var outputDirectory: URL
    public var archiveURL: URL
    public var appcastURL: URL
    public var metadata: ReleaseMetadata
    public var diagnostics: [Diagnostic]

    public init(
        version: String,
        outputDirectory: URL,
        archiveURL: URL,
        appcastURL: URL,
        metadata: ReleaseMetadata,
        diagnostics: [Diagnostic]
    ) {
        self.version = version
        self.outputDirectory = outputDirectory
        self.archiveURL = archiveURL
        self.appcastURL = appcastURL
        self.metadata = metadata
        self.diagnostics = diagnostics
    }
}
