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
                    "rm --recursive --force /", "echo hi; rm -fr /", "/bin/rm -rf /",
                    #"\rm -rf /"#, "r''m -rf /", #""rm" -rf /"#, "rm -rf /..", "rm -rf /tmp/../..",
                    "rm -rf ~", "rm -rf ~/", "rm -rf $HOME", "rm -rf ${HOME}/", "rm -rf \"$HOME\"",
                    "find / -delete", "find ~ -delete", "find / -exec rm {} +"] {
            XCTAssertTrue(c.isCommandBlocked(cmd), cmd)
        }
        for cmd in ["rm -rf ./build", "rm -f /tmp/x", "ls -la /", "rm -r /Users/me/old",
                    "rm -rf ~/old-build", "find . -delete", "find / -name x", "rm -rf $HOME/tmp/cache"] {
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

    func testCaptureScriptWritesOwnerOnlyFilesInScratchFolder() throws {
        let id = UUID().uuidString
        let dir = SeashellTemp.dir
        let scriptPath = "\(dir)/claude_script_\(id).sh"
        try createOutputCaptureScript(command: "echo hello", commandId: id)
            .write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: SeashellTemp.scriptPOSIXPermissions], ofItemAtPath: scriptPath)
        let out = "\(dir)/seashell_output_\(id).json"
        defer {
            for p in [scriptPath, out, out + ".complete"] { try? FileManager.default.removeItem(atPath: p) }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out), out)
        for path in [scriptPath, out] {
            let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0o777
            XCTAssertEqual(mode & 0o077, 0, "\(path) is readable by others: \(String(mode, radix: 8))")
        }
        XCTAssertTrue((try String(contentsOfFile: out, encoding: .utf8)).contains("hello"))
    }
}
