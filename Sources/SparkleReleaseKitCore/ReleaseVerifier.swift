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
        policy: ReleaseVerificationPolicy = .free
    ) throws -> [Diagnostic] {
        try inspect(
            archiveURL: archiveURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            policy: policy
        ).diagnostics
    }

    public func inspect(
        archiveURL: URL,
        expectedBundleIdentifier: String? = nil,
        policy: ReleaseVerificationPolicy = .free
    ) throws -> ReleaseInspectionResult {
        try policy.validate()
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            return ReleaseInspectionResult(
                metadata: nil,
                diagnostics: [.init(.failure, "Release archive", "The file does not exist: \(archiveURL.path)")]
            )
        }
        let archiveValues = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard archiveValues.isRegularFile == true, archiveValues.isSymbolicLink != true else {
            return ReleaseInspectionResult(
                metadata: nil,
                diagnostics: [.init(.failure, "Release archive", "The archive must be a regular, non-symlink file.")]
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

        let checksum = try FileDigest.sha256(of: archiveURL)
        var diagnostics: [Diagnostic] = [
            .init(.pass, "Archive SHA-256", checksum),
            .init(.pass, "Release policy", "Requested \(policy.releaseMode.rawValue) distribution mode."),
        ]
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
            let result = try ProcessRunner().run(
                "/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, archiveURL.path])
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

        let appURLs = findApps(in: extracted, waitForMountedVolume: mountedURL != nil)
        guard appURLs.count == 1, let appURL = appURLs.first else {
            let detail =
                appURLs.isEmpty
                ? "No safe .app bundle was found in the archive."
                : "The archive contains multiple top-level application bundles: \(appURLs.map(\.lastPathComponent).joined(separator: ", "))."
            diagnostics.append(
                .init(
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
        var executableURL: URL?

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let data = BoundedFileReader.data(at: infoURL, maximumBytes: 1_024 * 1_024),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            let identifier = plist["CFBundleIdentifier"] as? String ?? "unknown"
            let version = plist["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = plist["CFBundleVersion"] as? String ?? "unknown"
            let name =
                plist["CFBundleDisplayName"] as? String
                ?? plist["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent
            metadata = ReleaseMetadata(appName: name, bundleIdentifier: identifier, shortVersion: version, buildVersion: build)
            if let executable = plist["CFBundleExecutable"] as? String,
                !executable.isEmpty,
                executable == URL(fileURLWithPath: executable).lastPathComponent
            {
                executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executable)")
            } else {
                diagnostics.append(.init(.failure, "Main executable", "CFBundleExecutable is missing or unsafe."))
            }
            if let expectedBundleIdentifier, identifier != expectedBundleIdentifier {
                diagnostics.append(.init(.failure, "Bundle identifier", "Expected \(expectedBundleIdentifier), found \(identifier)."))
            } else {
                diagnostics.append(.init(.pass, "Bundle metadata", "\(identifier), version \(version) (\(build))."))
            }
        } else {
            diagnostics.append(.init(.failure, "Bundle metadata", "Contents/Info.plist is missing or invalid."))
        }

        let architectureResult = try inspectArchitectures(
            executableURL: executableURL,
            expected: policy.expectedArchitectures
        )
        diagnostics += architectureResult.diagnostics

        let signing = try inspectCodeSignature(appURL: appURL, policy: policy)
        diagnostics += signing.diagnostics

        let gatekeeper = try ProcessRunner().run(
            "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "execute", "--verbose=2", appURL.path]
        )
        let gatekeeperAccepted = gatekeeper.status == 0
        if gatekeeperAccepted {
            diagnostics.append(.init(.pass, "Gatekeeper assessment", "macOS accepted the application for execution."))
        } else if policy.requireNotarization {
            diagnostics.append(
                .init(
                    .failure,
                    "Gatekeeper assessment",
                    gatekeeper.standardError,
                    remediation: "Sign with Developer ID, notarize the release, staple the ticket, and rebuild the archive."
                ))
        } else {
            diagnostics.append(
                .init(
                    .warning,
                    "Gatekeeper assessment",
                    "Gatekeeper did not accept this build. That is expected for many free, independent builds and does not invalidate Sparkle's separate EdDSA update signature.",
                    remediation: "Document the one-time Gatekeeper approval, or optionally use Developer ID and notarization."
                ))
        }

        let stapler = try ProcessRunner().run(
            "/usr/bin/xcrun",
            arguments: ["stapler", "validate", appURL.path]
        )
        let stapledTicket = stapler.status == 0
        if stapledTicket {
            diagnostics.append(.init(.pass, "Notarization ticket", "A stapled Apple notarization ticket is valid."))
        } else if policy.requireNotarization {
            diagnostics.append(
                .init(
                    .failure,
                    "Notarization ticket",
                    "A valid stapled notarization ticket is required but was not found.",
                    remediation: "Notarize the Developer ID build and staple the accepted ticket before packaging."
                ))
        } else {
            diagnostics.append(
                .init(
                    .warning,
                    "Notarization ticket",
                    "No stapled Apple notarization ticket was detected. This is optional in free mode."
                ))
        }

        let sparkle = appURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        diagnostics.append(
            FileManager.default.fileExists(atPath: sparkle.path)
                ? .init(.pass, "Sparkle framework", "Sparkle.framework is embedded in the application.")
                : .init(
                    .failure, "Sparkle framework", "Sparkle.framework is not embedded.",
                    remediation: "Set Sparkle to Embed & Sign for the app target."))

        let effectiveMode: ReleaseMode =
            if policy.releaseMode == .auto {
                signing.kind == .developerID && gatekeeperAccepted && stapledTicket ? .developerID : .free
            } else {
                policy.releaseMode
            }
        diagnostics.append(
            .init(
                .pass,
                "Effective release mode",
                "The archive was evaluated as \(effectiveMode.rawValue) distribution."
            ))
        let artifact = ReleaseArtifactSummary(
            archiveBytes: archiveBytes,
            sha256: checksum,
            architectures: architectureResult.architectures,
            signingKind: signing.kind,
            teamIdentifier: signing.teamIdentifier,
            hardenedRuntime: signing.hardenedRuntime,
            gatekeeperAccepted: gatekeeperAccepted,
            stapledTicket: stapledTicket,
            requestedReleaseMode: policy.releaseMode,
            effectiveReleaseMode: effectiveMode
        )
        return ReleaseInspectionResult(metadata: metadata, artifact: artifact, diagnostics: diagnostics)
    }

    @available(*, deprecated, message: "Use the explicit ReleaseVerificationPolicy overload.")
    public func inspect(
        archiveURL: URL,
        expectedBundleIdentifier: String? = nil,
        notarizationRequired: Bool
    ) throws -> ReleaseInspectionResult {
        let policy = ReleaseVerificationPolicy(
            releaseMode: notarizationRequired ? .developerID : .free,
            requireSparkleSignature: true,
            requireDeveloperID: notarizationRequired,
            requireNotarization: notarizationRequired,
            allowAdHocSigning: !notarizationRequired,
            expectedArchitectures: [],
            expectedTeamIdentifier: nil
        )
        return try inspect(
            archiveURL: archiveURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            policy: policy
        )
    }

    private struct ArchitectureInspection {
        var architectures: [CPUArchitecture]
        var diagnostics: [Diagnostic]
    }

    private struct SigningInspection {
        var kind: CodeSigningKind
        var teamIdentifier: String?
        var hardenedRuntime: Bool
        var diagnostics: [Diagnostic]
    }

    private func inspectArchitectures(
        executableURL: URL?,
        expected: [CPUArchitecture]
    ) throws -> ArchitectureInspection {
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .init(
                architectures: [],
                diagnostics: [.init(.failure, "Executable architectures", "The main executable could not be located.")]
            )
        }
        let result = try ProcessRunner().run("/usr/bin/lipo", arguments: ["-archs", executableURL.path])
        guard result.status == 0 else {
            return .init(
                architectures: [],
                diagnostics: [.init(.failure, "Executable architectures", result.standardError)]
            )
        }
        let detected = Array(
            Set(
                result.standardOutput.split(whereSeparator: { $0.isWhitespace })
                    .compactMap { token -> CPUArchitecture? in
                        let value = String(token)
                        return value == "arm64e" ? .arm64 : CPUArchitecture(rawValue: value)
                    }
            )
        ).sorted()
        guard !detected.isEmpty else {
            return .init(
                architectures: [],
                diagnostics: [.init(.failure, "Executable architectures", "lipo returned no supported architecture.")]
            )
        }
        let missing = expected.filter { !detected.contains($0) }
        let detail = detected.map(\.rawValue).joined(separator: ", ")
        if missing.isEmpty {
            return .init(
                architectures: detected,
                diagnostics: [.init(.pass, "Executable architectures", detail)]
            )
        }
        return .init(
            architectures: detected,
            diagnostics: [
                .init(
                    .failure,
                    "Executable architectures",
                    "Detected \(detail); missing required \(missing.map(\.rawValue).joined(separator: ", ")).",
                    remediation: "Archive a build containing every architecture declared in sparklekit.json."
                )
            ]
        )
    }

    private func inspectCodeSignature(
        appURL: URL,
        policy: ReleaseVerificationPolicy
    ) throws -> SigningInspection {
        let verification = try ProcessRunner().run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
        )
        let details = try ProcessRunner().run(
            "/usr/bin/codesign",
            arguments: ["--display", "--verbose=4", appURL.path]
        )
        let output = details.standardOutput + "\n" + details.standardError
        let unsigned =
            output.localizedCaseInsensitiveContains("code object is not signed")
            || verification.standardError.localizedCaseInsensitiveContains("code object is not signed")
        let kind = classifySignature(output: output, unsigned: unsigned)
        let teamIdentifier = capture(#"TeamIdentifier=([^\r\n]+)"#, in: output).flatMap {
            $0 == "not set" ? nil : $0
        }
        let hardenedRuntime = output.contains("(runtime)") || output.contains("Runtime Version=")
        var diagnostics: [Diagnostic] = []

        if verification.status != 0 && !unsigned {
            diagnostics.append(
                .init(
                    .failure,
                    "Code signature",
                    verification.standardError.isEmpty ? "The code signature is malformed or incomplete." : verification.standardError,
                    remediation: "Sign every nested executable first and then sign the outer app bundle."
                ))
        } else {
            switch kind {
            case .developerID:
                diagnostics.append(.init(.pass, "Code signature", "A valid Developer ID Application signature is present."))
            case .adHoc:
                diagnostics.append(
                    .init(
                        policy.allowAdHocSigning && !policy.requireDeveloperID ? .pass : .failure,
                        "Code signature",
                        "A structurally valid ad-hoc signature is present.",
                        remediation: policy.allowAdHocSigning
                            ? nil : "Use Developer ID signing or select free mode with ad-hoc signing allowed."
                    ))
            case .unsigned:
                diagnostics.append(
                    .init(
                        policy.allowAdHocSigning && !policy.requireDeveloperID ? .warning : .failure,
                        "Code signature",
                        "The application is unsigned. Sparkle EdDSA can still authenticate the update archive, but macOS trust and update installation behavior are weaker.",
                        remediation: "Prefer a consistent ad-hoc signature for free distribution, or use Developer ID."
                    ))
            case .appleDevelopment:
                diagnostics.append(
                    .init(
                        policy.requireDeveloperID ? .failure : .warning,
                        "Code signature",
                        "An Apple Development signature is valid for development, not public Developer ID distribution."
                    ))
            case .other:
                diagnostics.append(
                    .init(
                        policy.requireDeveloperID ? .failure : .warning,
                        "Code signature",
                        "A valid signature is present, but it is not a Developer ID Application signature."
                    ))
            }
        }

        if policy.requireDeveloperID && kind != .developerID {
            diagnostics.append(
                .init(
                    .failure,
                    "Developer ID requirement",
                    "This release policy requires a Developer ID Application signature.",
                    remediation: "Sign the app with a Developer ID Application certificate, or use free mode."
                ))
        } else if kind != .developerID {
            diagnostics.append(
                .init(
                    .warning,
                    "Developer ID identity",
                    "Developer ID is not present. It is optional for free distribution and separate from Sparkle EdDSA signing."
                ))
        }

        if policy.requireDeveloperID {
            diagnostics.append(
                .init(
                    hardenedRuntime ? .pass : .failure,
                    "Hardened Runtime",
                    hardenedRuntime ? "Hardened Runtime is enabled." : "Developer ID mode requires Hardened Runtime."
                ))
        } else if hardenedRuntime {
            diagnostics.append(.init(.pass, "Hardened Runtime", "Hardened Runtime is enabled."))
        }

        if let expected = policy.expectedTeamIdentifier {
            diagnostics.append(
                .init(
                    teamIdentifier == expected ? .pass : .failure,
                    "Apple Team ID",
                    teamIdentifier == expected
                        ? "The signature belongs to Team ID \(expected)."
                        : "Expected Team ID \(expected), found \(teamIdentifier ?? "none")."
                ))
        }

        return .init(
            kind: kind,
            teamIdentifier: teamIdentifier,
            hardenedRuntime: hardenedRuntime,
            diagnostics: diagnostics
        )
    }

    private func classifySignature(output: String, unsigned: Bool) -> CodeSigningKind {
        if unsigned { return .unsigned }
        if output.contains("Authority=Developer ID Application:") { return .developerID }
        if output.contains("Authority=Apple Development:") { return .appleDevelopment }
        if output.contains("Signature=adhoc") || output.contains("flags=0x2(adhoc)") { return .adHoc }
        return .other
    }

    private func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateZIP(_ archiveURL: URL) throws -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let totals = try ProcessRunner().run("/usr/bin/zipinfo", arguments: ["-t", archiveURL.path])
        guard totals.status == 0,
            let summary = parseZIPSummary(totals.standardOutput)
        else {
            return [
                .init(
                    .failure, "ZIP structure", totals.standardError.isEmpty ? "zipinfo could not read the archive." : totals.standardError)
            ]
        }
        guard summary.entries > 0,
            summary.entries <= Self.maximumEntries,
            summary.expandedBytes <= Self.maximumExpandedBytes
        else {
            return [
                .init(
                    .failure,
                    "ZIP expansion limits",
                    "The archive declares \(summary.entries) entries and \(summary.expandedBytes) expanded bytes, which exceeds safe release limits."
                )
            ]
        }
        diagnostics.append(
            .init(
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
            diagnostics.append(
                .init(
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
            let bytes = Int64(output[bytesRange])
        else {
            return nil
        }
        return (entries, bytes)
    }

    private func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
            path.utf8.count <= 4_096,
            !path.hasPrefix("/"),
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !path.contains("\\")
        else {
            return false
        }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.last == "" { components.removeLast() }
        return !components.isEmpty
            && !components.contains {
                $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.count > 255
            }
    }

    private func validateExtractedTree(root: URL, allowApplicationsLink: Bool) -> [Diagnostic] {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
                options: []
            )
        else {
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
                resolved.path == "/Applications"
            {
                continue
            }
            guard contains(resolved, in: resolvedRoot) else {
                return [
                    .init(
                        .failure,
                        "Extracted paths",
                        values?.isSymbolicLink == true
                            ? "A symbolic link escapes the archive: \(url.lastPathComponent)"
                            : "An extracted path resolves outside the archive: \(url.lastPathComponent)"
                    )
                ]
            }
        }
        return [
            .init(
                .pass,
                "Extracted paths",
                allowApplicationsLink
                    ? "Extracted paths are contained; the standard top-level Applications link is allowed."
                    : "Extracted symbolic links remain inside the temporary directory."
            )
        ]
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    private func findApps(in root: URL, waitForMountedVolume: Bool = false) -> [URL] {
        let attempts = waitForMountedVolume ? 4 : 1
        for attempt in 0..<attempts {
            let applications = scanForApps(in: root)
            if !applications.isEmpty || attempt == attempts - 1 {
                return applications
            }
            Thread.sleep(forTimeInterval: 0.1 * Double(attempt + 1))
        }
        return []
    }

    private func scanForApps(in root: URL) -> [URL] {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        if root.pathExtension == "app" {
            let candidate = root.standardizedFileURL.resolvingSymlinksInPath()
            return contains(candidate, in: resolvedRoot) ? [candidate] : []
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else { return [] }
        var applications: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "app" {
            enumerator.skipDescendants()
            let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
            if contains(candidate, in: resolvedRoot) { applications.append(candidate) }
        }
        return applications.sorted { $0.path < $1.path }
    }

}
