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

/// Checks pid-posted clicks still land with short event gaps: set OCU_LIVE_EVENT_CLICK_APP to
/// an app whose front window has a text area with several lines of text (TextEdit). Each
/// trial puts the caret at 0, clicks the middle of the text with app_post, and expects it moved.
final class EventClickLiveTests: XCTestCase {
    func testPidPostedClicksLand() throws {
        let env = ProcessInfo.processInfo.environment
        guard let app = env["OCU_LIVE_EVENT_CLICK_APP"] else {
            throw XCTSkip("set OCU_LIVE_EVENT_CLICK_APP to check pid-posted clicks")
        }
        let trials = Int(env["OCU_LIVE_EVENT_CLICK_TRIALS"] ?? "") ?? 20
        let service = ComputerUseService()
        let state = try service.getAppState(app: app).textContent
        let line = try XCTUnwrap(state.split(separator: "\n").first { $0.contains("text entry area") })
        let index = String(line.trimmingCharacters(in: .whitespaces).split(separator: " ")[0])
        let snapshot = try service.currentSnapshot(for: app)
        let element = try XCTUnwrap(snapshot.elements[Int(index)!]?.element)
        func caret() -> Int? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            AXValueGetValue(value as! AXValue, .cfRange, &range)
            return range.location
        }
        var position = CGPoint.zero, size = CGSize.zero
        var raw: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw); AXValueGetValue(raw as! AXValue, .cgPoint, &position)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw); AXValueGetValue(raw as! AXValue, .cgSize, &size)
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        var landed = 0, posting: [Double] = [], processed: [Double] = []
        for _ in 0..<trials {
            var zero = CFRange(location: 0, length: 0)
            let value = AXValueCreate(.cfRange, &zero)!
            XCTAssertEqual(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value), .success)
            XCTAssertEqual(caret(), 0)
            let start = TimingLog.now()
            switch env["OCU_LIVE_EVENT_CLICK_METHOD"] ?? "raw" {
            case "sky": _ = try service.click(app: app, elementIndex: index, x: nil, y: nil, clickCount: 1, mouseButton: "left", clickMethod: .skyClick)
            case "app_post": _ = try service.click(app: app, elementIndex: index, x: nil, y: nil, clickCount: 1, mouseButton: "left", clickMethod: .appPost)
            default: try InputSimulation.clickTargeted(at: point, button: .left, clickCount: 1, pid: snapshot.app.pid)
            }
            posting.append((TimingLog.now() - start) * 1000)
            // How long after the last event the app shows the click.
            let posted = TimingLog.now()
            if waitUntil(timeout: 0.5, interval: 0.001, { (caret() ?? 0) > 0 }) != nil {
                landed += 1
                processed.append((TimingLog.now() - posted) * 1000)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        func median(_ v: [Double]) -> String { v.isEmpty ? "-" : String(format: "%.1f", v.sorted()[v.count / 2]) }
        print("pid-posted clicks landed \(landed)/\(trials); posting median \(median(posting)) ms; shown after posting: median \(median(processed)) ms, max \(String(format: "%.1f", processed.max() ?? 0)) ms")
        XCTAssertEqual(landed, trials)
    }
}

/// Types into a real field with the default method and checks the text arrived: set
/// OCU_LIVE_TYPE_APP, OCU_LIVE_TYPE_MATCH (text on the field's state line, e.g. "search text
/// field") and optionally OCU_LIVE_TYPE_TEXT. The field is cleared again afterwards.
final class TypeTextLiveTests: XCTestCase {
    func testDefaultTypingLands() throws {
        let env = ProcessInfo.processInfo.environment
        guard let app = env["OCU_LIVE_TYPE_APP"], let match = env["OCU_LIVE_TYPE_MATCH"] else {
            throw XCTSkip("set OCU_LIVE_TYPE_APP and OCU_LIVE_TYPE_MATCH to type into a real field")
        }
        let text = env["OCU_LIVE_TYPE_TEXT"] ?? "ocu"
        let service = ComputerUseService()
        let state = try service.getAppState(app: app).textContent
        let line = try XCTUnwrap(state.split(separator: "\n").first { $0.contains(match) }, "no line contains \(match)")
        let index = String(line.trimmingCharacters(in: .whitespaces).split(separator: " ")[0])
        let element = try XCTUnwrap(try service.currentSnapshot(for: app).elements[Int(index)!]?.element)
        func value() -> String {
            var raw: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw)
            return raw as? String ?? ""
        }
        _ = try service.click(app: app, elementIndex: index, x: nil, y: nil, clickCount: 1, mouseButton: "left", clickMethod: .auto)
        let before = value()
        let start = TimingLog.now()
        let result = try service.typeText(app: app, text: text)
        let elapsed = (TimingLog.now() - start) * 1000
        var after = value()
        let deadline = Date().addingTimeInterval(1)
        while !after.contains(text), Date() < deadline { Thread.sleep(forTimeInterval: 0.02); after = value() }
        _ = try service.pressKey(app: app, key: "super+a")
        _ = try service.pressKey(app: app, key: "BackSpace")
        print("type_text live: before \(before.debugDescription) after \(after.debugDescription) cleared \(value().debugDescription), \(String(format: "%.0f", elapsed)) ms")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(after.contains(text), "typed text did not arrive")
    }
}
