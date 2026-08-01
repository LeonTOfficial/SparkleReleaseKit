import Foundation

public struct SemanticVersion: Codable, Comparable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init?(_ value: String) {
        guard !value.isEmpty,
            value.utf8.count <= 255,
            !value.contains("+")
        else {
            return nil
        }
        let versionAndPrerelease = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let numbers = versionAndPrerelease[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard numbers.count == 3,
            let major = Int(numbers[0]),
            let minor = Int(numbers[1]),
            let patch = Int(numbers[2]),
            major >= 0,
            minor >= 0,
            patch >= 0,
            numbers.allSatisfy({ !$0.isEmpty && ($0 == "0" || !$0.hasPrefix("0")) })
        else {
            return nil
        }
        let prerelease =
            versionAndPrerelease.count == 2
            ? versionAndPrerelease[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            ).map(String.init)
            : []
        guard
            prerelease.allSatisfy({
                !$0.isEmpty
                    && $0.count <= 64
                    && $0.unicodeScalars.allSatisfy {
                        (48...57).contains($0.value)
                            || (65...90).contains($0.value)
                            || (97...122).contains($0.value)
                            || $0 == "-"
                    }
                    && (Int($0) == nil || $0 == "0" || !$0.hasPrefix("0"))
            })
        else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let leftCore = [lhs.major, lhs.minor, lhs.patch]
        let rightCore = [rhs.major, rhs.minor, rhs.patch]
        if leftCore != rightCore {
            return leftCore.lexicographicallyPrecedes(rightCore)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                return leftNumber < rightNumber
            }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
