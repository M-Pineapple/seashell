import XCTest
import Foundation
import Logging
import MCP
import ServiceLifecycle
@testable import Seashell

/// The server must stop when its stdio session ends (stdin EOF) or on SIGTERM,
/// so a client such as a container health check never waits on a stuck process.
final class ShutdownTests: XCTestCase {

    /// Stands in for the MCP stdio service finishing after stdin closes.
    private struct FinishesAtOnce: Service {
        func run() async throws {}
    }

    private func makeGroup(port: Int, sessionEnd: ServiceGroupConfiguration.ServiceConfiguration.TerminationBehavior) -> ServiceGroup {
        var logger = Logger(label: "seashell.tests.shutdown")
        logger.logLevel = .critical
        let server = Server(name: "seashell-test", version: "0", capabilities: .init(tools: .init()))
        let receiver = CommandReceiverService(port: port, server: server, logger: logger)
        return ServiceGroup(
            configuration: .init(
                services: [.init(service: receiver), .init(service: FinishesAtOnce(), successTerminationBehavior: sessionEnd)],
                logger: logger
            )
        )
    }

    /// Runs the group in a detached task so a regression fails on timeout instead of hanging the suite.
    /// Returns the error the group threw, or nil if it stopped cleanly.
    @discardableResult
    private func assertGroupStops(
        port: Int,
        sessionEnd: ServiceGroupConfiguration.ServiceConfiguration.TerminationBehavior = .gracefullyShutdownGroup,
        _ message: String
    ) async -> String? {
        let group = makeGroup(port: port, sessionEnd: sessionEnd)
        let stopped = expectation(description: message)
        let outcome = Outcome()
        Task.detached {
            do {
                try await group.run()
            } catch {
                await outcome.set("\(error)")
            }
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 5)
        return await outcome.error
    }

    private actor Outcome {
        var error: String?
        func set(_ value: String) { error = value }
    }

    func testCommandReceiverStopsWhenSessionEnds() async {
        let error = await assertGroupStops(port: Int.random(in: 40000...42999), "stops after the stdio session ends")
        XCTAssertNil(error, "a normal end of session should not be reported as a failure")
    }

    func testCommandReceiverStopsWhenGroupIsCancelled() async {
        await assertGroupStops(port: Int.random(in: 43000...44999), sessionEnd: .cancelGroup, "stops when the group is cancelled")
    }

    func testPortIsReleasedAfterShutdown() async {
        let port = Int.random(in: 45000...49999)
        await assertGroupStops(port: port, "first run stops")
        await assertGroupStops(port: port, "second run on the same port stops")
    }
}
