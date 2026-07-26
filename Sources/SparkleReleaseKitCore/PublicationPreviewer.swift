import Foundation

public enum PublicationPreviewError: LocalizedError {
    case invalidStage(URL)
    case missingManifest(URL)
    case tooManyAssets
    case unsafeAsset(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStage(let url):
            "The publication stage must be a readable, non-symlink directory: \(url.path)."
        case .missingManifest(let url):
            "The prepared release manifest is missing or invalid at \(url.path)."
        case .tooManyAssets:
            "The publication stage contains more than 100 top-level assets."
        case .unsafeAsset(let name):
            "The publication stage contains an unsafe or unsupported asset: \(name)"
        }
    }
}

public struct PublicationAsset: Codable, Equatable, Sendable {
    public var name: String
    public var bytes: Int64
    public var sha256: String
    public var downloadURL: String?

    public init(name: String, bytes: Int64, sha256: String, downloadURL: String?) {
        self.name = name
        self.bytes = bytes
        self.sha256 = sha256
        self.downloadURL = downloadURL
    }
}

public struct PublicationPreview: Codable, Sendable {
    public var repository: String
    public var tag: String
    public var version: String
    public var releaseMode: ReleaseMode
    public var feedURL: String
    public var assets: [PublicationAsset]
    public var requiredPermissions: [String]
    public var plannedRemoteWrites: [String]
    public var diagnostics: [Diagnostic]

    public init(
        repository: String,
        tag: String,
        version: String,
        releaseMode: ReleaseMode,
        feedURL: String,
        assets: [PublicationAsset],
        requiredPermissions: [String],
        plannedRemoteWrites: [String],
        diagnostics: [Diagnostic]
    ) {
        self.repository = repository
        self.tag = tag
        self.version = version
        self.releaseMode = releaseMode
        self.feedURL = feedURL
        self.assets = assets
        self.requiredPermissions = requiredPermissions
        self.plannedRemoteWrites = plannedRemoteWrites
        self.diagnostics = diagnostics
    }
}

public struct PublicationPreviewer: Sendable {
    private static let maximumAssetBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    public init() {}

    public func preview(
        stageURL: URL,
        configuration: SparkleKitConfiguration
    ) throws -> PublicationPreview {
        try ConfigurationStore().validate(configuration)
        let stage = stageURL.standardizedFileURL
        let values = try? stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw PublicationPreviewError.invalidStage(stage)
        }

        let manifestURL = try ProjectPathResolver.resolveForWrite(
            "release-manifest.json",
            under: stage
        )
        guard let manifestData = BoundedFileReader.data(
            at: manifestURL,
            maximumBytes: 1_024 * 1_024
        ), let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: manifestData) else {
            throw PublicationPreviewError.missingManifest(manifestURL)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: stage,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 100 else { throw PublicationPreviewError.tooManyAssets }

        let appcastURL = try ProjectPathResolver.resolveForWrite(manifest.appcast, under: stage)
        let appcast = try AppcastValidator().validate(fileURL: appcastURL)
        let downloadURLs = Dictionary(
            appcast.enclosures.map { (URL(string: $0.url)?.lastPathComponent ?? "", $0.url) },
            uniquingKeysWith: { first, _ in first }
        )

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleReleaseKit-PublishPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var assets: [PublicationAsset] = []
        for (index, file) in files.enumerated() {
            let fileValues = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true,
                  file.lastPathComponent == URL(fileURLWithPath: file.lastPathComponent).lastPathComponent
            else {
                throw PublicationPreviewError.unsafeAsset(file.lastPathComponent)
            }
            let snapshot = try StableFileSnapshot.create(
                from: file,
                in: temporary,
                maximumBytes: Self.maximumAssetBytes,
                fileName: "asset-\(index)"
            )
            assets.append(
                .init(
                    name: file.lastPathComponent,
                    bytes: snapshot.byteCount,
                    sha256: try FileDigest.sha256(of: snapshot.url),
                    downloadURL: downloadURLs[file.lastPathComponent]
                ))
        }

        var diagnostics = appcast.diagnostics
        if let archive = assets.first(where: { $0.name == manifest.archive }),
           archive.bytes == manifest.archiveBytes,
           archive.sha256 == manifest.sha256 {
            diagnostics.append(
                .init(
                    .pass,
                    "Publication stage integrity",
                    "The prepared archive still matches the manifest size and SHA-256.",
                    id: "SRK5101"
                ))
        } else {
            diagnostics.append(
                .init(
                    .failure,
                    "Publication stage integrity",
                    "The prepared archive no longer matches release-manifest.json.",
                    remediation: "Discard the stage and prepare the release again from the immutable archive.",
                    id: "SRK5103"
                ))
        }

        let checksumName = manifest.archive + ".sha256"
        let expectedChecksum = "\(manifest.sha256)  \(manifest.archive)\n"
        let checksumURL = try ProjectPathResolver.resolveForWrite(checksumName, under: stage)
        if let checksumData = BoundedFileReader.data(
            at: checksumURL,
            maximumBytes: 1_024
        ), String(data: checksumData, encoding: .utf8) == expectedChecksum {
            diagnostics.append(
                .init(
                    .pass,
                    "Publication checksum",
                    "\(checksumName) matches the prepared archive manifest.",
                    id: "SRK5102",
                    affectedComponent: checksumName
                ))
        } else {
            diagnostics.append(
                .init(
                    .failure,
                    "Publication checksum",
                    "\(checksumName) is missing or does not contain the exact prepared archive digest.",
                    remediation: "Discard the stage and prepare the release again; do not repair a staged checksum by hand.",
                    id: "SRK5103",
                    affectedComponent: checksumName
                ))
        }

        let repository = "\(configuration.github.owner)/\(configuration.github.repository)"
        return PublicationPreview(
            repository: repository,
            tag: "v\(manifest.shortVersion)",
            version: manifest.shortVersion,
            releaseMode: manifest.releaseMode,
            feedURL: configuration.updates.feedURL,
            assets: assets,
            requiredPermissions: [
                "GitHub release: contents: write",
                "GitHub Pages deployment: pages: write and id-token: write",
            ],
            plannedRemoteWrites: [
                "Create or update GitHub Release v\(manifest.shortVersion) in \(repository).",
                "Upload \(assets.count) reviewed stage assets without renaming them.",
                "Publish \(manifest.appcast) to \(configuration.updates.feedURL).",
            ],
            diagnostics: diagnostics
        )
    }
}
