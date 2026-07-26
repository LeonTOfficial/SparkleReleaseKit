import Foundation

public enum TerminalSanitizer {
    public static func text(_ value: String, preserveNewlines: Bool = true) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0A where preserveNewlines:
                result.append("\n")
            case 0x09:
                result.append("    ")
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
                result.append("\\u{\(String(scalar.value, radix: 16, uppercase: true))}")
            case 0x20...0x7E, 0xA0...0xD7FF, 0xE000...0x10FFFF:
                result.unicodeScalars.append(scalar)
            default:
                result.append("\\u{\(String(scalar.value, radix: 16, uppercase: true))}")
            }
        }
        return result
    }

    public static func indented(_ value: String, prefix: String) -> String {
        text(value).split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}
