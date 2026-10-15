import XCTest
import Foundation
@testable import Seashell

/// Guards for the 15 Oct 2026 hardening (blocklist coverage, scratch folder).
final class SweepGuardTests: XCTestCase {

    private func defaultConfig() throws -> Configuration {
        Configuration()
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Seashell/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBlocklistFoldsWhitespaceAndFlagOrder() throws {
        let c = try defaultConfig()
        for cmd in ["rm  -rf /", "rm\t-rf /", "rm -fr /", "rm -r -f /", "rm -Rf /*",
                    "rm --recursive --force /", "echo hi; rm -fr /", "/bin/rm -rf /"] {
            XCTAssertTrue(c.isCommandBlocked(cmd), cmd)
        }
        for cmd in ["rm -rf ./build", "rm -f /tmp/x", "ls -la /", "rm -r /Users/me/old"] {
            XCTAssertFalse(c.isCommandBlocked(cmd), cmd)
        }
    }

    func testEveryExecutionPathChecksBlocklist() throws {
        let pipeline = try source("PipelineAndStreaming.swift")
        XCTAssertGreaterThanOrEqual(pipeline.components(separatedBy: "config.isCommandBlocked(").count - 1, 4)
        for file in ["CommandHandlers.swift", "CommandHandlersStable.swift"] {
            XCTAssertTrue(try source(file).contains("config.isCommandBlocked(fullCommand)"), file)
        }
    }

    func testNoSharedTmpPathsInSources() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Seashell")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("\"/tmp/"), name)
            XCTAssertFalse(text.contains("= \"/tmp\""), name)
        }
    }

    func testScratchFolderIsPrivate() throws {
        let path = SeashellTemp.dir
        XCTAssertFalse(path.hasPrefix("/tmp/"))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
        XCTAssertEqual(SeashellTemp.scriptPOSIXPermissions, 0o700)
        XCTAssertTrue(createOutputCaptureScript(command: "true", commandId: "x").contains("umask 077"))
        XCTAssertTrue(createOutputCaptureScript(command: "true", commandId: "x").contains(path))
    }
}
