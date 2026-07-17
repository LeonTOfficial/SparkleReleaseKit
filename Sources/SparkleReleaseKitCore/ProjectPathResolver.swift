import Foundation

enum ProjectPathResolver {
    static func resolve(
        _ relativePath: String,
        under projectRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !relativePath.isEmpty,
              relativePath.utf8.count <= 4_096,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw IntegrationError.unsafePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.count > 255 }) else {
            throw IntegrationError.unsafePath(relativePath)
        }

        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var current = root
        for component in components {
            let candidate = current.appendingPathComponent(component).standardizedFileURL
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: candidate.path) {
                current = URL(fileURLWithPath: destination, relativeTo: current)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            } else {
                current = candidate
            }
            guard contains(current, in: root) else {
                throw IntegrationError.unsafePath(relativePath)
            }
        }
        return current
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        return resolvedCandidate.path == resolvedRoot.path || resolvedCandidate.path.hasPrefix(rootPath)
    }
}
