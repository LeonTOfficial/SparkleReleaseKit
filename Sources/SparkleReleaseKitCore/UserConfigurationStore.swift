import Darwin
import Foundation

public struct SparkleKitUserConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var updateChecksEnabled: Bool
    public var lastAutomaticUpdateCheck: Date?

    public init(
        schemaVersion: Int = 1,
        updateChecksEnabled: Bool = true,
        lastAutomaticUpdateCheck: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updateChecksEnabled = updateChecksEnabled
        self.lastAutomaticUpdateCheck = lastAutomaticUpdateCheck
    }
}

public enum UserConfigurationError: LocalizedError {
    case unsafePath
    case invalid
    case locked

    public var errorDescription: String? {
        switch self {
        case .unsafePath:
            "The SparkleReleaseKit user configuration path is unsafe."
        case .invalid:
            "The SparkleReleaseKit user configuration is invalid."
        case .locked:
            "Another SparkleReleaseKit process is updating user configuration."
        }
    }
}

public struct UserConfigurationStore: Sendable {
    private static let maximumBytes = 64 * 1_024
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    public func load() throws -> SparkleKitUserConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init()
        }
        guard
            let data = BoundedFileReader.data(
                at: url,
                maximumBytes: Self.maximumBytes
            )
        else {
            throw UserConfigurationError.unsafePath
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let configuration = try? decoder.decode(
                SparkleKitUserConfiguration.self,
                from: data
            ), configuration.schemaVersion == 1
        else {
            throw UserConfigurationError.invalid
        }
        return configuration
    }

    public func save(_ configuration: SparkleKitUserConfiguration) throws {
        guard configuration.schemaVersion == 1 else {
            throw UserConfigurationError.invalid
        }
        try prepareParent()
        if (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true {
            throw UserConfigurationError.unsafePath
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        try encoder.encode(configuration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public func setUpdateChecksEnabled(_ enabled: Bool) throws
        -> SparkleKitUserConfiguration
    {
        var configuration = try load()
        configuration.updateChecksEnabled = enabled
        try save(configuration)
        return configuration
    }

    public func claimAutomaticUpdateCheck(
        now: Date = Date(),
        minimumInterval: TimeInterval = 24 * 60 * 60
    ) throws -> Bool {
        guard minimumInterval > 0 else { return false }
        try prepareParent()
        let lockURL = url.deletingLastPathComponent()
            .appendingPathComponent("preferences.lock")
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw UserConfigurationError.locked
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw UserConfigurationError.locked
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        var configuration = try load()
        guard configuration.updateChecksEnabled else { return false }
        if let previous = configuration.lastAutomaticUpdateCheck,
            now.timeIntervalSince(previous) < minimumInterval
        {
            return false
        }
        configuration.lastAutomaticUpdateCheck = now
        try save(configuration)
        return true
    }

    private func prepareParent() throws {
        let parent = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path)
            || (try? FileManager.default.destinationOfSymbolicLink(
                atPath: parent.path
            )) != nil
        {
            let values = try parent.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                throw UserConfigurationError.unsafePath
            }
        } else {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
    }

    private static func defaultURL() -> URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(
            "SparkleReleaseKit/preferences.json"
        )
    }
}
