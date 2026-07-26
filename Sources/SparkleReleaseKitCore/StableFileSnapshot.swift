import Darwin
import Foundation

enum StableFileSnapshotError: LocalizedError {
    case unsafeSource(URL)
    case sourceTooLarge(Int64)
    case sourceChanged
    case destinationCreationFailed(URL)
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsafeSource(let url):
            "The source must be a readable, regular, non-symlink file: \(url.path)."
        case .sourceTooLarge(let bytes):
            "The source exceeds the allowed size limit (\(bytes) bytes)."
        case .sourceChanged:
            "The source changed while SparkleReleaseKit was taking a private snapshot."
        case .destinationCreationFailed(let url):
            "A private snapshot could not be created at \(url.path)."
        case .readFailed:
            "The source could not be read while taking a private snapshot."
        case .writeFailed:
            "The private snapshot could not be written completely."
        }
    }
}

struct StableFileSnapshot {
    var url: URL
    var byteCount: Int64

    static func create(
        from sourceURL: URL,
        in directory: URL,
        maximumBytes: Int64,
        fileName: String
    ) throws -> StableFileSnapshot {
        let sourceDescriptor = open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw StableFileSnapshotError.unsafeSource(sourceURL)
        }
        defer { close(sourceDescriptor) }

        var metadata = stat()
        guard fstat(sourceDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw StableFileSnapshotError.unsafeSource(sourceURL)
        }
        guard metadata.st_size <= maximumBytes else {
            throw StableFileSnapshotError.sourceTooLarge(metadata.st_size)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destinationURL = directory.appendingPathComponent(fileName)
        let destinationDescriptor = open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw StableFileSnapshotError.destinationCreationFailed(destinationURL)
        }
        var keepDestination = false
        defer {
            close(destinationDescriptor)
            if !keepDestination {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else { throw StableFileSnapshotError.readFailed }
            if count == 0 { break }
            guard total <= maximumBytes - Int64(count) else {
                throw StableFileSnapshotError.sourceTooLarge(total + Int64(count))
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    write(
                        destinationDescriptor,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                guard result > 0 else { throw StableFileSnapshotError.writeFailed }
                written += result
            }
            total += Int64(count)
        }
        guard total == metadata.st_size else {
            throw StableFileSnapshotError.sourceChanged
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw StableFileSnapshotError.writeFailed
        }
        keepDestination = true
        return StableFileSnapshot(url: destinationURL, byteCount: total)
    }
}
