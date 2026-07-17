import Foundation

public struct ReleaseVerifier: Sendable {
    private static let maximumArchiveBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    private static let maximumExpandedBytes: Int64 = 20 * 1_024 * 1_024 * 1_024
    private static let maximumEntries = 100_000
    private static let maximumListingBytes = 16 * 1_024 * 1_024

    public init() {}

    public func verify(
        archiveURL: URL,
        expectedBundleIdentifier: String? = nil,
        notarizationRequired: Bool = false
    ) throws -> [Diagnostic] {
        try inspect(
            archiveURL: archiveURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            notarizationRequired: notarizationRequired
        ).diagnostics
    }

    public func inspect(
        archiveURL: URL,
        expectedBundleIdentifier: String? = nil,
        notarizationRequired: Bool = false
    ) throws -> ReleaseInspectionResult {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            return ReleaseInspectionResult(
                metadata: nil,
                diagnostics: [.init(.failure, "Release archive", "The file does not exist: \(archiveURL.path)")]
            )
        }
        let archiveAttributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        let archiveBytes = (archiveAttributes[.size] as? NSNumber)?.int64Value ?? 0
        guard archiveBytes > 0, archiveBytes <= Self.maximumArchiveBytes else {
            return ReleaseInspectionResult(
                metadata: nil,
                diagnostics: [.init(.failure, "Archive size", "The archive is empty or exceeds the 8 GiB safety limit.")]
            )
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleReleaseKit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var mountedURL: URL?
        defer {
            if let mountedURL {
                _ = try? ProcessRunner().run("/usr/bin/hdiutil", arguments: ["detach", mountedURL.path])
            }
            try? FileManager.default.removeItem(at: temporary)
        }

        var diagnostics: [Diagnostic] = []
        let extracted: URL
        switch archiveURL.pathExtension.lowercased() {
        case "zip":
            let preflight = try validateZIP(archiveURL)
            diagnostics += preflight
            guard !preflight.contains(where: { $0.severity == .failure }) else {
                return ReleaseInspectionResult(metadata: nil, diagnostics: diagnostics)
            }
            let result = try ProcessRunner().run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, temporary.path])
            guard result.status == 0 else {
                diagnostics.append(.init(.failure, "ZIP extraction", result.standardError))
                return ReleaseInspectionResult(metadata: nil, diagnostics: diagnostics)
            }
            extracted = temporary
        case "dmg":
            let mount = temporary.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            let result = try ProcessRunner().run("/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, archiveURL.path])
            guard result.status == 0 else {
                diagnostics.append(.init(.failure, "DMG mount", result.standardError))
                return ReleaseInspectionResult(metadata: nil, diagnostics: diagnostics)
            }
            extracted = mount
            mountedURL = mount
            diagnostics.append(.init(.pass, "DMG mount", "Mounted the disk image read-only."))
        default:
            return ReleaseInspectionResult(
                metadata: nil,
                diagnostics: [.init(.failure, "Archive format", "Only ZIP and DMG release archives are currently supported.")]
            )
        }

        let treeDiagnostics = validateExtractedTree(
            root: extracted,
            allowApplicationsLink: archiveURL.pathExtension.lowercased() == "dmg"
        )
        diagnostics += treeDiagnostics
        guard !treeDiagnostics.contains(where: { $0.severity == .failure }) else {
            return ReleaseInspectionResult(metadata: nil, diagnostics: diagnostics)
        }

        let appURLs = findApps(in: extracted)
        guard appURLs.count == 1, let appURL = appURLs.first else {
            let detail = appURLs.isEmpty
                ? "No safe .app bundle was found in the archive."
                : "The archive contains multiple top-level application bundles: \(appURLs.map(\.lastPathComponent).joined(separator: ", "))."
            diagnostics.append(.init(
                .failure,
                "Application bundle",
                detail,
                remediation: "Package exactly one main macOS .app in each Sparkle update archive."
            ))
            return ReleaseInspectionResult(
                metadata: nil,
                diagnostics: diagnostics
            )
        }
        diagnostics.append(.init(.pass, "Application bundle", "Found \(appURL.lastPathComponent)."))
        var metadata: ReleaseMetadata?

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let data = BoundedFileReader.data(at: infoURL, maximumBytes: 1_024 * 1_024),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let identifier = plist["CFBundleIdentifier"] as? String ?? "unknown"
            let version = plist["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = plist["CFBundleVersion"] as? String ?? "unknown"
            let name = plist["CFBundleDisplayName"] as? String
                ?? plist["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent
            metadata = ReleaseMetadata(appName: name, bundleIdentifier: identifier, shortVersion: version, buildVersion: build)
            if let expectedBundleIdentifier, identifier != expectedBundleIdentifier {
                diagnostics.append(.init(.failure, "Bundle identifier", "Expected \(expectedBundleIdentifier), found \(identifier)."))
            } else {
                diagnostics.append(.init(.pass, "Bundle metadata", "\(identifier), version \(version) (\(build))."))
            }
        } else {
            diagnostics.append(.init(.failure, "Bundle metadata", "Contents/Info.plist is missing or invalid."))
        }

        let signature = try ProcessRunner().run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
        )
        diagnostics.append(signature.status == 0
            ? .init(.pass, "Code signature", "The application and its nested code have structurally valid signatures.")
            : .init(.failure, "Code signature", signature.standardError, remediation: "Sign every nested executable and then the outer app bundle."))

        let gatekeeper = try ProcessRunner().run(
            "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "execute", "--verbose=2", appURL.path]
        )
        if gatekeeper.status == 0 {
            diagnostics.append(.init(.pass, "Gatekeeper assessment", "macOS accepted the application for execution."))
        } else if notarizationRequired {
            diagnostics.append(.init(
                .failure,
                "Gatekeeper assessment",
                gatekeeper.standardError,
                remediation: "Sign with Developer ID, notarize the release, staple the ticket, and rebuild the archive."
            ))
        } else {
            diagnostics.append(.init(
                .warning,
                "Gatekeeper assessment",
                "Gatekeeper did not accept this build. This can be expected for local or ad-hoc builds, but public releases should be notarized.",
                remediation: "Use Developer ID signing and Apple notarization before public distribution."
            ))
        }

        let sparkle = appURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        diagnostics.append(FileManager.default.fileExists(atPath: sparkle.path)
            ? .init(.pass, "Sparkle framework", "Sparkle.framework is embedded in the application.")
            : .init(.failure, "Sparkle framework", "Sparkle.framework is not embedded.", remediation: "Set Sparkle to Embed & Sign for the app target."))

        return ReleaseInspectionResult(metadata: metadata, diagnostics: diagnostics)
    }

    private func validateZIP(_ archiveURL: URL) throws -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let totals = try ProcessRunner().run("/usr/bin/zipinfo", arguments: ["-t", archiveURL.path])
        guard totals.status == 0,
              let summary = parseZIPSummary(totals.standardOutput) else {
            return [.init(.failure, "ZIP structure", totals.standardError.isEmpty ? "zipinfo could not read the archive." : totals.standardError)]
        }
        guard summary.entries > 0,
              summary.entries <= Self.maximumEntries,
              summary.expandedBytes <= Self.maximumExpandedBytes else {
            return [.init(
                .failure,
                "ZIP expansion limits",
                "The archive declares \(summary.entries) entries and \(summary.expandedBytes) expanded bytes, which exceeds safe release limits."
            )]
        }
        diagnostics.append(.init(
            .pass,
            "ZIP expansion limits",
            "\(summary.entries) entries, \(summary.expandedBytes) bytes after extraction."
        ))

        let listing = try ProcessRunner().run("/usr/bin/zipinfo", arguments: ["-1", archiveURL.path])
        guard listing.status == 0 else {
            diagnostics.append(.init(.failure, "ZIP member paths", listing.standardError))
            return diagnostics
        }
        guard listing.standardOutput.utf8.count <= Self.maximumListingBytes else {
            diagnostics.append(.init(.failure, "ZIP member paths", "The archive member listing exceeds the 16 MiB safety limit."))
            return diagnostics
        }

        let unsafe = listing.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !isSafeArchivePath($0) }
        if let first = unsafe.first {
            diagnostics.append(.init(
                .failure,
                "ZIP member paths",
                "The archive contains an unsafe member path: \(first)",
                remediation: "Create the update ZIP with ditto --keepParent from a clean .app bundle."
            ))
        } else {
            diagnostics.append(.init(.pass, "ZIP member paths", "Every archive member stays within the extraction directory."))
        }
        return diagnostics
    }

    private func parseZIPSummary(_ output: String) -> (entries: Int, expandedBytes: Int64)? {
        let pattern = #"([0-9]+) files?, ([0-9]+) bytes uncompressed"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let entriesRange = Range(match.range(at: 1), in: output),
              let bytesRange = Range(match.range(at: 2), in: output),
              let entries = Int(output[entriesRange]),
              let bytes = Int64(output[bytesRange]) else {
            return nil
        }
        return (entries, bytes)
    }

    private func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.contains("\\") else {
            return false
        }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.last == "" { components.removeLast() }
        return !components.isEmpty && !components.contains {
            $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.count > 255
        }
    }

    private func validateExtractedTree(root: URL, allowApplicationsLink: Bool) -> [Diagnostic] {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return [.init(.failure, "Extracted paths", "The extracted archive could not be enumerated safely.")]
        }

        var entries = 0
        var expandedBytes: Int64 = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= Self.maximumEntries else {
                return [.init(.failure, "Extracted limits", "The mounted or extracted archive exceeds 100,000 entries.")]
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard relative.isEmpty || isSafeArchivePath(relative) else {
                return [.init(.failure, "Extracted paths", "An extracted path contains unsafe characters or components.")]
            }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if let size = (try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).flatMap({ values in
                values.isRegularFile == true ? values.fileSize : nil
            }) {
                let fileBytes = Int64(size)
                guard fileBytes <= Self.maximumExpandedBytes - expandedBytes else {
                    return [.init(.failure, "Extracted limits", "The mounted or extracted archive exceeds 20 GiB.")]
                }
                expandedBytes += fileBytes
            }
            if values?.isSymbolicLink == true,
               allowApplicationsLink,
               relative == "Applications",
               resolved.path == "/Applications" {
                continue
            }
            guard contains(resolved, in: resolvedRoot) else {
                return [.init(
                    .failure,
                    "Extracted paths",
                    values?.isSymbolicLink == true
                        ? "A symbolic link escapes the archive: \(url.lastPathComponent)"
                        : "An extracted path resolves outside the archive: \(url.lastPathComponent)"
                )]
            }
        }
        return [.init(
            .pass,
            "Extracted paths",
            allowApplicationsLink
                ? "Extracted paths are contained; the standard top-level Applications link is allowed."
                : "Extracted symbolic links remain inside the temporary directory."
        )]
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    private func findApps(in root: URL) -> [URL] {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        if root.pathExtension == "app" {
            let candidate = root.standardizedFileURL.resolvingSymlinksInPath()
            return contains(candidate, in: resolvedRoot) ? [candidate] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var applications: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "app" {
            enumerator.skipDescendants()
            let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
            if contains(candidate, in: resolvedRoot) { applications.append(candidate) }
        }
        return applications.sorted { $0.path < $1.path }
    }

}
