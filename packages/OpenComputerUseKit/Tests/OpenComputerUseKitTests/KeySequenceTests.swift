import XCTest
@testable import OpenComputerUseKit

final class KeySequenceTests: XCTestCase {
    private func steps(_ json: String) throws -> [KeySequenceStep] {
        try KeySequence.parse(JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testWalkAndJumpTimelineParsesAndResolves() throws {
        let parsed = try steps(#"[{"down":"w"},{"wait_ms":300},{"press":"space"},{"wait_ms":700},{"up":"w"}]"#)
        XCTAssertEqual(parsed, [.down("w"), .wait(milliseconds: 300), .press("space"), .wait(milliseconds: 700), .up("w")])
        let resolved = try KeySequence.resolve(parsed)
        XCTAssertEqual(resolved.count, 5)
        XCTAssertEqual(resolved[1], .wait(0.3))
    }

    func testOverlappingHeldKeysAndModifiersAreAllowed() throws {
        XCTAssertNoThrow(try KeySequence.resolve([.down("w"), .down("d"), .down("shift"), .press("space"), .up("d")]),
                         "keys left held at the end are released by run, so they are not an error")
        XCTAssertNotNil(try KeySequence.heldKey("Shift", step: 1).modifierFlag)
        XCTAssertNil(try KeySequence.heldKey("w", step: 1).modifierFlag)
    }

    func testBadTimelinesFailBeforeAnythingIsSent() throws {
        let bad: [[KeySequenceStep]] = [
            [],
            [.up("w")],
            [.down("w"), .down("W")],
            [.down("w+space")],
            [.press("nosuchkey")],
            [.wait(milliseconds: 6_000), .wait(milliseconds: 5_000)],
            Array(repeating: .press("a"), count: KeySequence.maximumSteps + 1),
        ]
        for timeline in bad {
            XCTAssertThrowsError(try KeySequence.resolve(timeline), "\(timeline.prefix(2))")
        }
    }

    func testStepObjectsNeedExactlyOneKnownAction() {
        for json in [
            #"{"down":"w"}"#,
            #"[{"down":"w","up":"w"}]"#,
            #"[{"hold":"w"}]"#,
            #"[{"down":""}]"#,
            #"[{"wait_ms":-1}]"#,
            #"[{"wait_ms":"300"}]"#,
        ] {
            XCTAssertThrowsError(try steps(json), json)
        }
    }

    func testToolSchemaListsTheFourActions() throws {
        let tool = try XCTUnwrap(ToolDefinitions.all.first { $0.name == "key_sequence" })
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let items = try XCTUnwrap((properties["steps"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(Set((items["properties"] as? [String: Any])?.keys ?? [:].keys), ["down", "up", "press", "wait_ms"])
        XCTAssertEqual(tool.inputSchema["required"] as? [String], ["app", "steps"])
    }
}
