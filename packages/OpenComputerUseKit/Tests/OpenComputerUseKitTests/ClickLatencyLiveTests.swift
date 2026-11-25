import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Times real clicks end to end: set OCU_LIVE_CLICK_APP (a running app), OCU_LIVE_CLICK_INDEX
/// (an element index from its state) and optionally OCU_LIVE_CLICK_COUNT. With
/// OPEN_COMPUTER_USE_DEBUG_TIMING=1 each stage's time goes to stderr.
final class ClickLatencyLiveTests: XCTestCase {
    func testClickLatency() throws {
        let env = ProcessInfo.processInfo.environment
        guard let app = env["OCU_LIVE_CLICK_APP"], let index = env["OCU_LIVE_CLICK_INDEX"] else {
            throw XCTSkip("set OCU_LIVE_CLICK_APP and OCU_LIVE_CLICK_INDEX to time real clicks")
        }
        let count = Int(env["OCU_LIVE_CLICK_COUNT"] ?? "") ?? 8
        let service = ComputerUseService()
        _ = try service.getAppState(app: app)
        var times: [Double] = []
        for _ in 0..<count {
            let start = TimingLog.now()
            let result = try service.click(app: app, elementIndex: index, x: nil, y: nil, clickCount: 1, mouseButton: "left", clickMethod: .auto)
            times.append((TimingLog.now() - start) * 1000)
            XCTAssertFalse(result.isError)
            fputs("[open-computer-use] timing click.total \(String(format: "%.1f", times.last!))ms\n", stderr)
        }
        let sorted = times.sorted()
        print("click latency ms:", times.map { String(format: "%.0f", $0) }.joined(separator: " "), "median", String(format: "%.0f", sorted[sorted.count / 2]))
    }
}
