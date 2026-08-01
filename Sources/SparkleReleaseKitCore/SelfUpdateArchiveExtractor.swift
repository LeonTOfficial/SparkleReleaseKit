import Foundation

struct SelfUpdateArchiveExtractor: Sendable {
    private static let maximumEntries = 10_000
    private static let maximumExpandedBytes: Int64 = 512 * 1_024 * 1_024
    private static let maximumListingBytes = 8 * 1_024 * 1_024

    func extract(
        archiveURL: URL,
        to destination: URL,
        executablePath: String,
        resourceBundlePath: String
    ) throws -> (executable: URL, resourceBundle: URL) {
        try preflight(archiveURL)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: destination.path
        )
        let extraction = try ProcessRunner().run(
            "/usr/bin/ditto",
            arguments: ["-x", "-k", archiveURL.path, destination.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            inheritEnvironment: false,
            timeout: 120
        )
        guard processSucceeded(extraction) else {
            throw SelfUpdateError.unsafeArchive
        }
        try validateTree(destination)
        let executable = try resolvedExpectedPath(
            executablePath,
            root: destination
        )
        let resourceBundle = try resolvedExpectedPath(
            resourceBundlePath,
            root: destination
        )
        let executableValues = try executable.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]
        )
        let bundleValues = try resourceBundle.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard executableValues.isRegularFile == true,
            executableValues.isSymbolicLink != true,
            executableValues.isExecutable == true,
            bundleValues.isDirectory == true,
            bundleValues.isSymbolicLink != true
        else {
            throw SelfUpdateError.unsafeArchive
        }
        return (executable, resourceBundle)
    }

    private func preflight(_ archive: URL) throws {
        let summary = try ProcessRunner().run(
            "/usr/bin/zipinfo",
            arguments: ["-t", archive.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            inheritEnvironment: false,
            timeout: 30
        )
        guard processSucceeded(summary),
            let totals = parseSummary(summary.standardOutput),
            totals.entries > 0,
            totals.entries <= Self.maximumEntries,
            totals.expandedBytes <= Self.maximumExpandedBytes
        else {
            throw SelfUpdateError.unsafeArchive
        }

        let listing = try ProcessRunner().run(
            "/usr/bin/zipinfo",
            arguments: ["-1", archive.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            inheritEnvironment: false,
            timeout: 30
        )
        guard processSucceeded(listing),
            listing.standardOutput.utf8.count <= Self.maximumListingBytes
        else {
            throw SelfUpdateError.unsafeArchive
        }
        let paths = listing.standardOutput.split(
            whereSeparator: \.isNewline
        ).map(String.init)
        guard paths.count <= Self.maximumEntries,
            paths.allSatisfy(safeArchivePath)
        else {
            throw SelfUpdateError.unsafeArchive
        }

        let modes = try ProcessRunner().run(
            "/usr/bin/zipinfo",
            arguments: ["-l", archive.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            inheritEnvironment: false,
            timeout: 30
        )
        guard processSucceeded(modes),
            modes.standardOutput.utf8.count <= Self.maximumListingBytes,
            !containsSpecialArchiveEntry(modes.standardOutput)
        else {
            throw SelfUpdateError.unsafeArchive
        }
    }

    private func validateTree(_ root: URL) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: []
            )
        else {
            throw SelfUpdateError.unsafeArchive
        }
        var entries = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= Self.maximumEntries else {
                throw SelfUpdateError.unsafeArchive
            }
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isSymbolicLink != true,
                values.isDirectory == true || values.isRegularFile == true,
                contains(
                    url.standardizedFileURL.resolvingSymlinksInPath(),
                    in: canonicalRoot
                )
            else {
                throw SelfUpdateError.unsafeArchive
            }
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                guard size >= 0,
                    bytes <= Self.maximumExpandedBytes - size
                else {
                    throw SelfUpdateError.unsafeArchive
                }
                bytes += size
            }
        }
    }

    private func resolvedExpectedPath(
        _ relativePath: String,
        root: URL
    ) throws -> URL {
        do {
            return try ProjectPathResolver.resolveForWrite(
                relativePath,
                under: root
            )
        } catch {
            throw SelfUpdateError.unsafeArchive
        }
    }

    private func parseSummary(
        _ output: String
    ) -> (entries: Int, expandedBytes: Int64)? {
        let expression = try? NSRegularExpression(
            pattern: #"([0-9]+) files?, ([0-9]+) bytes uncompressed"#
        )
        guard let expression,
            let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
            ),
            let entriesRange = Range(match.range(at: 1), in: output),
            let bytesRange = Range(match.range(at: 2), in: output),
            let entries = Int(output[entriesRange]),
            let bytes = Int64(output[bytesRange])
        else {
            return nil
        }
        return (entries, bytes)
    }

    private func safeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
            path.utf8.count <= 4_096,
            !path.hasPrefix("/"),
            !path.contains("\\"),
            !path.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
            )
        else {
            return false
        }
        var components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        if components.last == "" { components.removeLast() }
        return !components.isEmpty
            && !components.contains {
                $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.count > 255
            }
    }

    private func containsSpecialArchiveEntry(_ listing: String) -> Bool {
        listing.range(
            of: #"(?m)^[bclps][rwxStTs-]{9}\s"#,
            options: .regularExpression
        ) != nil
    }

    private func processSucceeded(_ result: ProcessResult) -> Bool {
        result.status == 0
            && !result.timedOut
            && !result.standardOutputTruncated
            && !result.standardErrorTruncated
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}
