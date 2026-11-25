import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class PointerInputTests: XCTestCase {
    func testDragPathEndsOnTargetInBothSpaces() {
        let start = SkyPointerPoint(screen: CGPoint(x: 110, y: 220), window: CGPoint(x: 10, y: 20))
        let end = SkyPointerPoint(screen: CGPoint(x: 310, y: 220), window: CGPoint(x: 210, y: 20))
        let path = skyDragPath(from: start, to: end, steps: 4)
        XCTAssertEqual(path.count, 4)
        XCTAssertEqual(path.first?.screen, CGPoint(x: 160, y: 220))
        XCTAssertEqual(path.last, end)
        XCTAssertEqual(skyDragPath(from: start, to: end, steps: 0).count, 1)
    }

    func testScrollGoesOutAsSmallNotches() {
        let down = skyScrollTicks(direction: "down", pages: 1)
        XCTAssertEqual(down.count, 4)
        XCTAssertEqual(down.map(\.wheel1).reduce(0, +), -12)
        XCTAssertTrue(down.allSatisfy { $0.wheel2 == 0 })
        let left = skyScrollTicks(direction: "left", pages: 0.5)
        XCTAssertEqual(left.map(\.wheel2), [3, 3])
        XCTAssertEqual(skyScrollTicks(direction: "up", pages: 0.01).map(\.wheel1), [1])
        XCTAssertEqual(skyScrollTicks(direction: "up", pages: 1_000_000).count, 400, "capped at 1200 lines")
    }

    func testDragPlanTriesSkyFirstUnlessGlobalIsOn() throws {
        let on = ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1"]
        XCTAssertEqual(try dragDeliveryPlan(method: .auto, environment: [:]), [.sky, .appPost])
        XCTAssertEqual(try dragDeliveryPlan(method: .auto, environment: on), [.global])
        XCTAssertEqual(try dragDeliveryPlan(method: .sky, environment: on), [.sky])
        XCTAssertEqual(try dragDeliveryPlan(method: .appPost, environment: [:]), [.appPost])
        XCTAssertThrowsError(try dragDeliveryPlan(method: .global, environment: [:]))
        XCTAssertEqual(try dragDeliveryPlan(method: .global, environment: on), [.global])
    }

    func testDragMethodParsing() throws {
        XCTAssertEqual(try parseDragMethod(nil), .auto)
        XCTAssertEqual(try parseDragMethod(" Sky "), .sky)
        XCTAssertEqual(try parseDragMethod("app_post"), .appPost)
        XCTAssertThrowsError(try parseDragMethod("sky_click"))
    }

    func testPointerToolSchemas() throws {
        let tools = Dictionary(uniqueKeysWithValues: ToolDefinitions.all.map { ($0.name, $0) })
        let scroll = try XCTUnwrap(tools["scroll"]).inputSchema
        XCTAssertEqual(scroll["required"] as? [String], ["app", "direction"])
        let scrollProperties = try XCTUnwrap(scroll["properties"] as? [String: [String: Any]])
        XCTAssertNotNil(scrollProperties["x"])
        XCTAssertNotNil(scrollProperties["y"])

        let drag = try XCTUnwrap(tools["drag"]).inputSchema
        let dragProperties = try XCTUnwrap(drag["properties"] as? [String: [String: Any]])
        XCTAssertEqual(dragProperties["mouse_button"]?["enum"] as? [String], ["left", "right", "middle"])
        XCTAssertEqual(dragProperties["drag_method"]?["enum"] as? [String], ["auto", "sky", "app_post", "global"])
        XCTAssertEqual(dragProperties["duration_ms"]?["type"] as? String, "number")

        let hover = try XCTUnwrap(tools["hover"])
        XCTAssertEqual(hover.inputSchema["required"] as? [String], ["app"])
        XCTAssertTrue(hover.description.hasSuffix("This tool is part of plugin `Computer Use`."))
    }

    func testPointerArgumentErrors() {
        let dispatcher = ComputerUseToolDispatcher()
        let both = dispatcher.callToolAsResult(
            name: "scroll",
            arguments: ["app": "Sublime Text", "element_index": "14", "x": 10, "y": 10, "direction": "down"]
        )
        XCTAssertTrue(both.isError)
        XCTAssertEqual(both.primaryText, "scroll takes element_index or x/y, not both")

        let badButton = dispatcher.callToolAsResult(
            name: "drag",
            arguments: ["app": "Sublime Text", "from_x": 1, "from_y": 1, "to_x": 2, "to_y": 2, "mouse_button": "fourth"]
        )
        XCTAssertTrue(badButton.isError)
        XCTAssertEqual(badButton.primaryText, "mouse_button must be left, right or middle")

        let badMethod = dispatcher.callToolAsResult(
            name: "drag",
            arguments: ["app": "Sublime Text", "from_x": 1, "from_y": 1, "to_x": 2, "to_y": 2, "drag_method": "warp"]
        )
        XCTAssertTrue(badMethod.isError)
        XCTAssertTrue(badMethod.primaryText?.hasPrefix("Invalid drag_method 'warp'") == true)

        let badDuration = dispatcher.callToolAsResult(
            name: "drag",
            arguments: ["app": "Sublime Text", "from_x": 1, "from_y": 1, "to_x": 2, "to_y": 2, "duration_ms": -5]
        )
        XCTAssertTrue(badDuration.isError)
        XCTAssertEqual(badDuration.primaryText, "duration_ms must be between 0 and 10000")
    }
}

final class PointerSideEffectTests: XCTestCase {
    func testOnlyAWarpOntoTheDragIsUndone() {
        let sent = [CGPoint(x: 400, y: 300), CGPoint(x: 500, y: 300)]
        XCTAssertTrue(pointerWasWarpedOntoPath(before: CGPoint(x: 10, y: 10), now: CGPoint(x: 400.5, y: 301), sent: sent))
        XCTAssertFalse(pointerWasWarpedOntoPath(before: CGPoint(x: 10, y: 10), now: CGPoint(x: 450, y: 300), sent: sent), "the user moved it")
        XCTAssertFalse(pointerWasWarpedOntoPath(before: CGPoint(x: 400, y: 300), now: CGPoint(x: 400, y: 300), sent: sent), "never moved")
    }

    func testSideEffectNote() {
        XCTAssertNil(dragSideEffectNote(SkyPointerSideEffects()))
        let note = dragSideEffectNote(SkyPointerSideEffects(restoredPointer: true, targetTookFront: true, restoredFrontApp: true))
        XCTAssertEqual(note, "The app warped the real pointer onto the drag (a mouse lock, as a game camera does); it was moved back. The app came to the front during the drag; the previous app was brought back.")
    }
}
