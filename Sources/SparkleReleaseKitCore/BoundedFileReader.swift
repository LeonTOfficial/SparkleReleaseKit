import Darwin
import Foundation

enum BoundedFileReader {
    static func data(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0 else { return nil }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else {
            return nil
        }

        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        while result.count <= maximumBytes {
            let remaining = maximumBytes - result.count + 1
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(64 * 1_024, remaining))
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { return result }
            result.append(chunk)
        }
        return nil
    }

    static func string(at url: URL, maximumBytes: Int) -> String? {
        guard let data = data(at: url, maximumBytes: maximumBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
