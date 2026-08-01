import Foundation

public struct DiagnosticDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var explanation: String
    public var recommendedAction: String
    public var documentationURL: String

    public init(
        id: String,
        title: String,
        explanation: String,
        recommendedAction: String,
        documentationURL: String
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.recommendedAction = recommendedAction
        self.documentationURL = documentationURL
    }
}

public enum DiagnosticCatalog {
    private static let documentationRoot =
        "https://github.com/LeonTOfficial/SparkleReleaseKit/blob/main/docs/"

    public static let definitions: [String: DiagnosticDefinition] = [
        "SRK1001": .init(
            id: "SRK1001",
            title: "Missing official Sparkle dependency",
            explanation: "The selected application target does not visibly reference the official Sparkle package and product.",
            recommendedAction: "Add https://github.com/sparkle-project/Sparkle and link the Sparkle product to the selected app target.",
            documentationURL: documentationRoot + "QUICKSTART.md"
        ),
        "SRK1103": .init(
            id: "SRK1103",
            title: "Existing custom Sparkle integration detected",
            explanation: "Custom updater code must be preserved and reviewed before generated files are applied.",
            recommendedAction: "Keep the custom integration and use SparkleReleaseKit as a validation and release-preparation layer.",
            documentationURL: documentationRoot + "ARCHITECTURE.md"
        ),
        "SRK2102": .init(
            id: "SRK2102",
            title: "Ad-hoc signature conflicts with Library Validation",
            explanation: "A hardened, ad-hoc-signed app can reject Sparkle components when Library Validation remains enabled.",
            recommendedAction: "Choose a compatible signing design, or disable Library Validation only after reviewing the security consequences.",
            documentationURL: documentationRoot + "FREE_DISTRIBUTION.md"
        ),
        "SRK2103": .init(
            id: "SRK2103",
            title: "Nested code signature is invalid",
            explanation: "At least one executable or nested bundle does not have a valid individual code signature.",
            recommendedAction: "Sign nested code first and the outer application last, then rebuild the archive.",
            documentationURL: documentationRoot + "RELEASE_PROCESS.md"
        ),
        "SRK2204": .init(
            id: "SRK2204",
            title: "Required sandbox entitlement missing",
            explanation: "A sandboxed updater needs the entitlements required by its selected Sparkle integration.",
            recommendedAction: "Review the app sandbox and network entitlements against the official Sparkle sandbox guidance.",
            documentationURL: documentationRoot + "TROUBLESHOOTING.md"
        ),
        "SRK3005": .init(
            id: "SRK3005",
            title: "Multiple app targets found",
            explanation: "SparkleReleaseKit will not silently choose among several application targets, schemes, or containers.",
            recommendedAction: "Select the intended container, target, and scheme explicitly.",
            documentationURL: documentationRoot + "CLI_REFERENCE.md"
        ),
        "SRK4102": .init(
            id: "SRK4102",
            title: "Appcast archive size mismatch",
            explanation: "The appcast enclosure length does not match the exact archive bytes being authenticated.",
            recommendedAction: "Regenerate the appcast from the immutable release archive.",
            documentationURL: documentationRoot + "UPDATE_SIGNING.md"
        ),
        "SRK4201": .init(
            id: "SRK4201",
            title: "Invalid Sparkle EdDSA signature",
            explanation: "The enclosure signature does not authenticate the selected archive with the configured public key.",
            recommendedAction: "Use the correct production key and regenerate the appcast from the unchanged archive.",
            documentationURL: documentationRoot + "UPDATE_SIGNING.md"
        ),
        "SRK4401": .init(
            id: "SRK4401",
            title: "Untrusted generate_appcast helper",
            explanation: "The selected signing helper did not satisfy the configured path, ownership, code-signature, or SHA-256 trust policy.",
            recommendedAction: "Use the reviewed generate_appcast from the supported Sparkle release and configure an exact hash or signing requirement when stronger pinning is needed.",
            documentationURL: documentationRoot + "SECURITY_MODEL.md"
        ),
        "SRK5103": .init(
            id: "SRK5103",
            title: "Published archive checksum mismatch",
            explanation: "A published release asset differs from the archive that was prepared and verified locally.",
            recommendedAction: "Stop rollout, replace the asset through a new reviewed release, and verify every public URL again.",
            documentationURL: documentationRoot + "RELEASE_PROCESS.md"
        ),
    ]

    public static func definition(for id: String) -> DiagnosticDefinition? {
        definitions[id.uppercased()]
    }

    public static func identifier(for title: String) -> String {
        switch title {
        case "Official Sparkle package": return "SRK1001"
        case "Updater source": return "SRK1002"
        case "Release workflow": return "SRK1003"
        case "Configuration": return "SRK1004"
        case "Generated Info.plist settings", "Info.plist", "Info.plist path", "SUFeedURL", "SUPublicEDKey": return "SRK1005"
        case "Secret protection": return "SRK1201"
        case "Tracked secret scan", "Tracked secret filenames", "Tracked secret contents": return "SRK1202"
        case "Code signature": return "SRK2101"
        case "Library Validation": return "SRK2102"
        case "Nested code signatures": return "SRK2103"
        case "Sandbox entitlements": return "SRK2204"
        case "Developer ID requirement", "Developer ID identity": return "SRK2301"
        case "Hardened Runtime": return "SRK2302"
        case "Apple Team ID": return "SRK2303"
        case "Gatekeeper assessment": return "SRK2304"
        case "Notarization ticket": return "SRK2305"
        case "Xcode command-line tools": return "SRK3001"
        case "Git": return "SRK3002"
        case "Xcode project": return "SRK3003"
        case "Package resolution", "Package network access": return "SRK3004"
        case "Release build": return "SRK3006"
        case "RSS structure": return "SRK4001"
        case "Update items": return "SRK4002"
        case "Version uniqueness": return "SRK4005"
        case "Sparkle EdDSA signature": return "SRK4201"
        case "Release archive", "Archive format", "Archive size": return "SRK4301"
        case "Archive SHA-256": return "SRK4302"
        case "Release policy", "Effective release mode": return "SRK4303"
        case "ZIP extraction", "DMG mount": return "SRK4304"
        case "ZIP structure", "ZIP expansion limits", "ZIP member paths": return "SRK4305"
        case "Extracted paths", "Extracted limits": return "SRK4306"
        case "Application bundle": return "SRK4307"
        case "Main executable", "Bundle identifier", "Bundle metadata": return "SRK4308"
        case "Executable architectures": return "SRK4309"
        case "Sparkle framework": return "SRK4310"
        case "generate_appcast trust": return "SRK4401"
        default:
            if title.hasPrefix("Item ") && title.hasSuffix(" download URL") { return "SRK4003" }
            if title.hasPrefix("Item ") && title.hasSuffix(" enclosure") { return "SRK4004" }
            if title.hasPrefix("Item ") && title.hasSuffix(" version") { return "SRK4006" }
            if title.hasPrefix("Item ") && title.hasSuffix(" EdDSA signature") { return "SRK4200" }
            if title.hasPrefix("Item ") && title.hasSuffix(" length") { return "SRK4102" }
            if title.hasPrefix("Nested signature ") { return "SRK2103" }
            return "SRK9000"
        }
    }
}
