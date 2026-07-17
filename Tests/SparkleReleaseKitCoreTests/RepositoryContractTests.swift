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
        let schema = root.appendingPathComponent("schemas/sparklekit.schema.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: schema))

        #expect(object is [String: Any])
        for path in ["website/index.html", "website/docs/index.html", "website/security/index.html"] {
            let content = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(content.contains("<!doctype html>"))
            #expect(content.contains("SparkleReleaseKit"))
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
