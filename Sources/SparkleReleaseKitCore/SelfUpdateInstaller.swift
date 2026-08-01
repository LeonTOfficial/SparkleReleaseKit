import Darwin
import Foundation

public struct SelfUpdateInstaller: Sendable {
    public static let resourceBundleName =
        "SparkleReleaseKit_SparkleReleaseKitCore.bundle"
    private static let maximumBundleEntries = 10_000
    private static let maximumBundleBytes: Int64 = 64 * 1_024 * 1_024

    private let afterActivation: @Sendable () throws -> Void

    public init() {
        afterActivation = {}
    }

    init(afterActivation: @escaping @Sendable () throws -> Void) {
        self.afterActivation = afterActivation
    }

    public func install(
        packageExecutable: URL,
        packageResourceBundle: URL,
        newVersion: String,
        installedVersion: String,
        installationPath: URL
    ) throws -> SelfUpdateInstallResult {
        guard SemanticVersion(newVersion) != nil,
            SemanticVersion(installedVersion) != nil
        else {
            throw SelfUpdateError.invalidInstalledVersion
        }
        let install = try validatedInstallationPath(installationPath)
        let parent = install.deletingLastPathComponent()
        let management = try managementDirectory(parent: parent)
        let lock = try acquireLock(management: management)
        defer { releaseLock(lock) }

        let current = try currentInstallation(
            installationPath: install,
            version: installedVersion,
            management: management
        )
        let versionDirectory = try managedDirectory(
            "versions/v\(newVersion)-\(UUID().uuidString)",
            management: management
        )
        var keepVersionDirectory = false
        defer {
            if !keepVersionDirectory {
                try? FileManager.default.removeItem(at: versionDirectory)
            }
        }

        let newExecutable = versionDirectory.appendingPathComponent(
            "sparklekit"
        )
        let newBundle = versionDirectory.appendingPathComponent(
            Self.resourceBundleName
        )
        guard resourceBundleIsSafe(packageResourceBundle) else {
            throw SelfUpdateError.invalidDownloadedExecutable
        }
        try FileManager.default.copyItem(
            at: packageExecutable,
            to: newExecutable
        )
        try FileManager.default.copyItem(
            at: packageResourceBundle,
            to: newBundle
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: current.permissions],
            ofItemAtPath: newExecutable.path
        )
        guard resourceBundleIsSafe(newBundle) else {
            throw SelfUpdateError.invalidDownloadedExecutable
        }
        try verifyExecutable(
            newExecutable,
            expectedSHA256: try FileDigest.sha256(of: packageExecutable),
            requireCodeSignature: true
        )

        let previous = try backupIfNeeded(
            current,
            management: management
        )
        let replacement = InstallationReference(
            version: newVersion,
            binaryPath: newExecutable.path,
            resourceBundlePath: newBundle.path,
            sha256: try FileDigest.sha256(of: newExecutable),
            permissions: current.permissions,
            codeSignatureRequired: true
        )
        let activation = try activate(
            target: newExecutable,
            at: install
        )
        do {
            try afterActivation()
            try saveState(
                .init(
                    schemaVersion: 1,
                    installationPath: install.path,
                    current: replacement,
                    previous: previous
                ),
                management: management
            )
        } catch {
            activation.restore()
            throw SelfUpdateError.installationFailed
        }
        activation.commit()
        keepVersionDirectory = true
        return SelfUpdateInstallResult(
            previousVersion: installedVersion,
            installedVersion: newVersion,
            installationPath: install.path,
            backupPath: previous.binaryPath
        )
    }

    public func rollback(
        installationPath: URL
    ) throws -> SelfUpdateRollbackResult {
        let install = try validatedInstallationPath(installationPath)
        let parent = install.deletingLastPathComponent()
        let management = try managementDirectory(parent: parent)
        let lock = try acquireLock(management: management)
        defer { releaseLock(lock) }
        let state = try loadState(management: management)
        guard state.installationPath == install.path,
            let previous = state.previous
        else {
            throw SelfUpdateError.missingRollback
        }
        try verifyReference(previous, management: management)
        let previousBundle = URL(
            fileURLWithPath: previous.resourceBundlePath
        )
        guard resourceBundleIsSafe(previousBundle) else {
            throw SelfUpdateError.invalidRollback
        }

        let activation = try activate(
            target: URL(fileURLWithPath: previous.binaryPath),
            at: install
        )
        do {
            try saveState(
                .init(
                    schemaVersion: 1,
                    installationPath: install.path,
                    current: previous,
                    previous: state.current
                ),
                management: management
            )
        } catch {
            activation.restore()
            throw SelfUpdateError.installationFailed
        }
        activation.commit()
        return SelfUpdateRollbackResult(
            restoredVersion: previous.version,
            replacedVersion: state.current.version,
            installationPath: install.path
        )
    }

    private struct InstallationReference: Codable, Equatable {
        var version: String
        var binaryPath: String
        var resourceBundlePath: String
        var sha256: String
        var permissions: Int
        var codeSignatureRequired: Bool
    }

    private struct InstallationState: Codable {
        var schemaVersion: Int
        var installationPath: String
        var current: InstallationReference
        var previous: InstallationReference?
    }

    private struct UpdateLock {
        var descriptor: Int32
    }

    private final class Activation {
        private let restoreHandler: () -> Void
        private let commitHandler: () -> Void
        private var finished = false

        init(
            restore: @escaping () -> Void,
            commit: @escaping () -> Void
        ) {
            restoreHandler = restore
            commitHandler = commit
        }

        func restore() {
            guard !finished else { return }
            restoreHandler()
            finished = true
        }

        func commit() {
            guard !finished else { return }
            commitHandler()
            finished = true
        }
    }

    private func validatedInstallationPath(_ input: URL) throws -> URL {
        guard input.path.hasPrefix("/"),
            input.lastPathComponent == "sparklekit",
            input.lastPathComponent
                == URL(
                    fileURLWithPath: input.lastPathComponent
                ).lastPathComponent
        else {
            throw SelfUpdateError.unsafeInstallationPath
        }
        let parent = input.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let install = parent.appendingPathComponent(input.lastPathComponent)
        guard
            FileManager.default.fileExists(atPath: install.path)
                || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: install.path
                )) != nil,
            FileManager.default.isWritableFile(atPath: parent.path)
        else {
            throw SelfUpdateError.installationNotWritable
        }
        return install
    }

    private func managementDirectory(parent: URL) throws -> URL {
        let management = parent.appendingPathComponent(".sparklekit")
        if FileManager.default.fileExists(atPath: management.path)
            || (try? FileManager.default.destinationOfSymbolicLink(
                atPath: management.path
            )) != nil
        {
            let values = try management.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                throw SelfUpdateError.unsafeInstallationPath
            }
        } else {
            try FileManager.default.createDirectory(
                at: management,
                withIntermediateDirectories: false
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: management.path
        )
        return management
    }

    private func currentInstallation(
        installationPath: URL,
        version: String,
        management: URL
    ) throws -> InstallationReference {
        let binary: URL
        if let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: installationPath.path)
        {
            binary = URL(
                fileURLWithPath: destination,
                relativeTo: installationPath.deletingLastPathComponent()
            ).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            binary = installationPath
        }
        let values = try? binary.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]
        )
        guard values?.isRegularFile == true,
            values?.isSymbolicLink != true,
            values?.isExecutable == true
        else {
            throw SelfUpdateError.unsafeInstallationPath
        }
        let bundle = binary.deletingLastPathComponent()
            .appendingPathComponent(Self.resourceBundleName)
        guard resourceBundleIsSafe(bundle) else {
            throw SelfUpdateError.unsafeInstallationPath
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: binary.path
        )
        let permissions =
            (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        return InstallationReference(
            version: version,
            binaryPath: binary.path,
            resourceBundlePath: bundle.path,
            sha256: try FileDigest.sha256(of: binary),
            permissions: permissions & 0o777,
            codeSignatureRequired: codeSignatureValid(binary)
        )
    }

    private func backupIfNeeded(
        _ current: InstallationReference,
        management: URL
    ) throws -> InstallationReference {
        let currentBinary = URL(fileURLWithPath: current.binaryPath)
        if ProjectPathResolver.contains(currentBinary, in: management) {
            return current
        }
        let backup = try managedDirectory(
            "backups/v\(current.version)-\(UUID().uuidString)",
            management: management
        )
        let binary = backup.appendingPathComponent("sparklekit")
        let bundle = backup.appendingPathComponent(Self.resourceBundleName)
        do {
            try FileManager.default.copyItem(
                at: currentBinary,
                to: binary
            )
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: current.resourceBundlePath),
                to: bundle
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: current.permissions],
                ofItemAtPath: binary.path
            )
            guard resourceBundleIsSafe(bundle) else {
                throw SelfUpdateError.unsafeInstallationPath
            }
            return InstallationReference(
                version: current.version,
                binaryPath: binary.path,
                resourceBundlePath: bundle.path,
                sha256: try FileDigest.sha256(of: binary),
                permissions: current.permissions,
                codeSignatureRequired: current.codeSignatureRequired
            )
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
    }

    private func verifyReference(
        _ reference: InstallationReference,
        management: URL
    ) throws {
        do {
            try validateStoredReference(reference, management: management)
            try verifyExecutable(
                URL(fileURLWithPath: reference.binaryPath),
                expectedSHA256: reference.sha256,
                requireCodeSignature: reference.codeSignatureRequired
            )
        } catch {
            throw SelfUpdateError.invalidRollback
        }
    }

    private func managedDirectory(
        _ relativePath: String,
        management: URL
    ) throws -> URL {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let hasUnsafeComponent = components.contains { component in
            component.isEmpty
                || component == "."
                || component == ".."
                || component.utf8.count > 255
        }
        guard !components.isEmpty,
            !hasUnsafeComponent
        else {
            throw SelfUpdateError.unsafeInstallationPath
        }
        var current = management
        for component in components {
            current.appendPathComponent(String(component))
            if FileManager.default.fileExists(atPath: current.path)
                || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: current.path
                )) != nil
            {
                let values = try current.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true,
                    values.isSymbolicLink != true
                else {
                    throw SelfUpdateError.unsafeInstallationPath
                }
            } else {
                try FileManager.default.createDirectory(
                    at: current,
                    withIntermediateDirectories: false
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: current.path
            )
        }
        return current
    }

    private func verifyExecutable(
        _ url: URL,
        expectedSHA256: String,
        requireCodeSignature: Bool
    ) throws {
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]
        )
        guard values?.isRegularFile == true,
            values?.isSymbolicLink != true,
            values?.isExecutable == true,
            try FileDigest.sha256(of: url) == expectedSHA256,
            !requireCodeSignature || codeSignatureValid(url)
        else {
            throw SelfUpdateError.invalidDownloadedExecutable
        }
    }

    private func codeSignatureValid(_ url: URL) -> Bool {
        guard
            let result = try? ProcessRunner().run(
                "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--verbose=2", url.path],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                inheritEnvironment: false,
                timeout: 30
            )
        else {
            return false
        }
        return result.status == 0
            && !result.timedOut
            && !result.standardOutputTruncated
            && !result.standardErrorTruncated
    }

    private func activate(target: URL, at installationPath: URL) throws
        -> Activation
    {
        let parent = installationPath.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".sparklekit-link-\(UUID().uuidString)"
        )
        guard symlink(target.path, temporary.path) == 0 else {
            throw SelfUpdateError.installationFailed
        }
        let wasSymlink =
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: installationPath.path
            )) != nil
        if wasSymlink {
            let oldDestination = try FileManager.default
                .destinationOfSymbolicLink(atPath: installationPath.path)
            guard rename(temporary.path, installationPath.path) == 0 else {
                _ = unlink(temporary.path)
                throw SelfUpdateError.installationFailed
            }
            return Activation(
                restore: {
                    let restore = parent.appendingPathComponent(
                        ".sparklekit-restore-\(UUID().uuidString)"
                    )
                    guard symlink(oldDestination, restore.path) == 0 else {
                        return
                    }
                    if rename(restore.path, installationPath.path) != 0 {
                        _ = unlink(restore.path)
                    }
                },
                commit: {}
            )
        }

        guard
            renameatx_np(
                AT_FDCWD,
                temporary.path,
                AT_FDCWD,
                installationPath.path,
                UInt32(RENAME_SWAP)
            ) == 0
        else {
            _ = unlink(temporary.path)
            throw SelfUpdateError.installationFailed
        }
        return Activation(
            restore: {
                if renameatx_np(
                    AT_FDCWD,
                    temporary.path,
                    AT_FDCWD,
                    installationPath.path,
                    UInt32(RENAME_SWAP)
                ) == 0 {
                    _ = unlink(temporary.path)
                }
            },
            commit: {
                _ = unlink(temporary.path)
            }
        )
    }

    private func stateURL(_ management: URL) -> URL {
        management.appendingPathComponent("update-state.json")
    }

    private func saveState(
        _ state: InstallationState,
        management: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        let url = stateURL(management)
        if (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true {
            throw SelfUpdateError.unsafeInstallationPath
        }
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func loadState(management: URL) throws -> InstallationState {
        let url = stateURL(management)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SelfUpdateError.missingRollback
        }
        guard
            let data = BoundedFileReader.data(
                at: url,
                maximumBytes: 1_024 * 1_024
            ),
            let state = try? JSONDecoder().decode(
                InstallationState.self,
                from: data
            ), state.schemaVersion == 1
        else {
            throw SelfUpdateError.invalidRollback
        }
        try validateStoredReference(state.current, management: management)
        if let previous = state.previous {
            try validateStoredReference(previous, management: management)
        }
        return state
    }

    private func validateStoredReference(
        _ reference: InstallationReference,
        management: URL
    ) throws {
        let binary = URL(fileURLWithPath: reference.binaryPath)
            .standardizedFileURL
        let bundle = URL(fileURLWithPath: reference.resourceBundlePath)
            .standardizedFileURL
        guard SemanticVersion(reference.version) != nil,
            reference.binaryPath == binary.path,
            reference.resourceBundlePath == bundle.path,
            binary.lastPathComponent == "sparklekit",
            bundle.lastPathComponent == Self.resourceBundleName,
            binary.deletingLastPathComponent().path
                == bundle.deletingLastPathComponent().path,
            ProjectPathResolver.contains(binary, in: management),
            ProjectPathResolver.contains(bundle, in: management),
            reference.sha256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil,
            reference.permissions > 0,
            reference.permissions <= 0o777,
            reference.permissions & 0o111 != 0
        else {
            throw SelfUpdateError.invalidRollback
        }
    }

    private func resourceBundleIsSafe(_ bundle: URL) -> Bool {
        let values = try? bundle.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values?.isDirectory == true,
            values?.isSymbolicLink != true
        else {
            return false
        }
        let root = bundle.standardizedFileURL.resolvingSymlinksInPath()
        guard
            let enumerator = FileManager.default.enumerator(
                at: bundle,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
        else {
            return false
        }
        var entries = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= Self.maximumBundleEntries,
                let values = try? url.resourceValues(
                    forKeys: [
                        .isDirectoryKey, .isRegularFileKey,
                        .isSymbolicLinkKey, .fileSizeKey,
                    ]
                ),
                values.isSymbolicLink != true,
                values.isDirectory == true || values.isRegularFile == true,
                ProjectPathResolver.contains(url, in: root)
            else {
                return false
            }
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? -1)
                guard size >= 0,
                    bytes <= Self.maximumBundleBytes - size
                else {
                    return false
                }
                bytes += size
            }
        }
        return true
    }

    private func acquireLock(management: URL) throws -> UpdateLock {
        let path = management.appendingPathComponent("update.lock").path
        let descriptor = open(
            path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SelfUpdateError.updateAlreadyRunning
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_uid == geteuid(),
            metadata.st_nlink == 1,
            metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
            fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            close(descriptor)
            throw SelfUpdateError.unsafeInstallationPath
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SelfUpdateError.updateAlreadyRunning
        }
        return UpdateLock(descriptor: descriptor)
    }

    private func releaseLock(_ lock: UpdateLock) {
        _ = flock(lock.descriptor, LOCK_UN)
        close(lock.descriptor)
    }
}
