import Foundation
import Testing
@testable import SparkleReleaseKitCore

@Suite("Repository contracts")
struct RepositoryContractTests {
    @Test("Published example configuration matches the runtime model")
    func exampleConfigurationLoads() throws {
        let root = repositoryRoot()
        let configuration = try ConfigurationStore().load(
            from: root.appendingPathComponent("examples/sparklekit.example.json")
        )

        #expect(configuration.schemaVersion == SparkleKitConfiguration.currentSchemaVersion)
        #expect(configuration.updates.publicEDKey.isEmpty)
        #expect(configuration.updates.sparkleVersion == SparkleKitConfiguration.supportedSparkleVersion)
    }

    @Test("JSON schema and website entry points are valid JSON and HTML")
    func repositoryArtifactsExist() throws {
        let root = repositoryRoot()
        for path in [
            "schemas/sparklekit.schema.json",
            "schemas/sparklekit-cli-output.schema.json",
        ] {
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent(path))
            )
            #expect(object is [String: Any])
        }
        for path in ["website/index.html", "website/docs/index.html", "website/security/index.html"] {
            let content = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(content.contains("<!doctype html>"))
            #expect(content.contains("SparkleReleaseKit"))
        }
    }

    @Test("External GitHub Actions references use immutable commit SHAs")
    func workflowDependenciesArePinned() throws {
        let root = repositoryRoot()
        let workflowRoot = root.appendingPathComponent(".github/workflows")
        var files = try FileManager.default.contentsOfDirectory(
            at: workflowRoot,
            includingPropertiesForKeys: nil
        ).filter { ["yml", "yaml"].contains($0.pathExtension) }
        files.append(root.appendingPathComponent("Sources/SparkleReleaseKitCore/Resources/Templates/sparkle-release.yml.template"))

        let expression = try NSRegularExpression(pattern: #"uses:\s+[^\s@]+@([^\s#]+)"#)
        var references = 0
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(content.startIndex..., in: content)
            for match in expression.matches(in: content, range: range) {
                let referenceRange = try #require(Range(match.range(at: 1), in: content))
                let reference = String(content[referenceRange])
                references += 1
                #expect(reference.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil)
            }
        }
        #expect(references >= 8)
    }

    @Test("Workflow checkouts discard credentials and release tags originate on main")
    func workflowsProtectRepositoryCredentials() throws {
        let root = repositoryRoot()
        let workflowRoot = root.appendingPathComponent(".github/workflows")
        let files = try FileManager.default.contentsOfDirectory(
            at: workflowRoot,
            includingPropertiesForKeys: nil
        ).filter { ["yml", "yaml"].contains($0.pathExtension) }

        var checkoutCount = 0
        var protectedCheckoutCount = 0
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            checkoutCount += content.components(separatedBy: "uses: actions/checkout@").count - 1
            protectedCheckoutCount += content.components(separatedBy: "persist-credentials: false").count - 1
        }
        #expect(checkoutCount > 0)
        #expect(protectedCheckoutCount == checkoutCount)

        let release = try String(
            contentsOf: workflowRoot.appendingPathComponent("release.yml"),
            encoding: .utf8
        )
        #expect(release.contains("fetch-depth: 0"))
        #expect(release.contains("git merge-base --is-ancestor"))
        #expect(release.contains("refs/remotes/origin/main"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
