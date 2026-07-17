import Foundation

enum BoundedFileReader {
    static func data(at url: URL, maximumBytes: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func string(at url: URL, maximumBytes: Int) -> String? {
        guard let data = data(at: url, maximumBytes: maximumBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
