import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Each MCP session (each chat) owns its cursor: own queue generation, own window tracker,
/// own on-screen panel and colour.
@MainActor
final class SessionCursorTests: XCTestCase {
    func testOneSessionsResetDoesNotDropAnothersQueuedWork() {
        _ = NSApplication.shared
        @MainActor final class Recording { var played: [String] = [] }
        let recording = Recording()
        let a = VisualCursorChannel.makeSession()
        let b = VisualCursorChannel.makeSession()
        let submitted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            a.performOnMain { recording.played.append("a") }
            b.performOnMain { recording.played.append("b") }
            a.resetOnMain()
            submitted.signal()
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 3), .success)
        let drained = expectation(description: "drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(recording.played, ["b"], "resetting chat A cancels only A's queued cursor work")
    }

    func testGlidesTakeHandSpeedTimeAndClassicKeepsTheOfficialOne() {
        let official = OfficialCursorMotionModel.closeEnoughTime
        XCTAssertGreaterThan(official, 1, "the official spring plays well over a second")
        let button = visualCursorTravelDuration(distance: 40, calibrated: official, environment: [:])
        let window = visualCursorTravelDuration(distance: 400, calibrated: official, environment: [:])
        let screen = visualCursorTravelDuration(distance: 3000, calibrated: official, environment: [:])
        XCTAssertEqual(visualCursorTravelDuration(distance: 0, calibrated: official, environment: [:]), 0.12, accuracy: 0.001)
        XCTAssertLessThan(button, window)
        XCTAssertLessThan(window, screen)
        XCTAssertEqual(screen, 0.4, accuracy: 0.001)
        XCTAssertEqual(visualCursorTravelDuration(distance: 400, calibrated: official, environment: ["OPEN_COMPUTER_USE_CURSOR_MOTION": "classic"]), official)
    }

    func testTurnEndedResetsEverySession() {
        let a = VisualCursorChannel.makeSession()
        let b = VisualCursorChannel.makeSession()
        let (ga, gb) = (a.generation, b.generation)
        resetOpenComputerUseVisualCursor()
        XCTAssertNotEqual(a.generation, ga)
        XCTAssertNotEqual(b.generation, gb)
    }

    func testSessionsTrackTheirOwnWindows() {
        let a = VisualCursorChannel.makeSession()
        let b = VisualCursorChannel.makeSession()
        XCTAssertFalse(a.frames === b.frames)
        XCTAssertFalse(a.frames === VisualCursorChannel.shared.frames)
        XCTAssertTrue(VisualCursorChannel.shared.frames === CursorWindowFrameTracker.shared)
        a.frames.installFrameOverrideForTesting { _ in CGRect(x: 1, y: 2, width: 300, height: 200) }
        XCTAssertNotNil(a.frames.liveFrame(for: 7))
        XCTAssertNil(b.frames.liveFrame(for: 7), "one session's window does not evict or answer for another's")
    }

    func testEachServiceGetsItsOwnCursor() {
        XCTAssertFalse(ComputerUseService().visualCursor === ComputerUseService().visualCursor)
    }

    func testColoursCycleAndTheDefaultCursorKeepsItsOwn() {
        XCTAssertEqual(visualCursorSessionTint(index: 0), visualCursorSessionTints[0])
        XCTAssertEqual(visualCursorSessionTint(index: visualCursorSessionTints.count + 1), visualCursorSessionTints[1])
        XCTAssertEqual(Set(visualCursorSessionTints.map(\.description)).count, visualCursorSessionTints.count, "colours are distinct")
        XCTAssertNil(VisualCursorChannel.shared.overlay.tintForTesting)
        let a = VisualCursorChannel.makeSession().overlay.tintForTesting
        let b = VisualCursorChannel.makeSession().overlay.tintForTesting
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b, "consecutive chats get different colours")
    }

    func testTwoSessionCursorsShowAtOnceInTheirOwnPlaces() throws {
        _ = NSApplication.shared
        guard let frame = NSScreen.main?.visibleFrame else { throw XCTSkip("requires a display") }
        let a = VisualCursorChannel.makeSession()
        let b = VisualCursorChannel.makeSession()
        defer { a.overlay.reset(); b.overlay.reset() }
        let left = CGPoint(x: frame.minX + frame.width * 0.3, y: frame.midY)
        let right = CGPoint(x: frame.minX + frame.width * 0.7, y: frame.midY)
        a.overlay.moveCursor(to: left, in: nil)
        a.overlay.settle(at: left, in: nil)
        b.overlay.moveCursor(to: right, in: nil)
        b.overlay.settle(at: right, in: nil)
        XCTAssertTrue(a.overlay.isOnScreenForTesting)
        XCTAssertTrue(b.overlay.isOnScreenForTesting)
        let tipA = try XCTUnwrap(a.overlay.tipPositionForTesting)
        let tipB = try XCTUnwrap(b.overlay.tipPositionForTesting)
        XCTAssertLessThan(abs(tipA.x - left.x), 2)
        XCTAssertLessThan(abs(tipB.x - right.x), 2)

        a.resetOnMain()
        XCTAssertFalse(a.overlay.isOnScreenForTesting, "chat A ended")
        XCTAssertTrue(b.overlay.isOnScreenForTesting, "chat B's cursor stays")
        XCTAssertLessThan(abs((b.overlay.tipPositionForTesting?.x ?? 0) - right.x), 2)
    }

    /// Tool calls queue cursor work off the main thread. Chat B's glide must play while
    /// chat A's is still moving, not wait for it on the main queue.
    func testTwoChatsGlideAtTheSameTime() throws {
        _ = NSApplication.shared
        guard let frame = NSScreen.main?.visibleFrame else { throw XCTSkip("requires a display") }
        let a = VisualCursorChannel.makeSession()
        let b = VisualCursorChannel.makeSession()
        defer { a.overlay.reset(); b.overlay.reset() }
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
        }
        let (startA, endA, startB, endB) = (at(0.15, 0.7), at(0.85, 0.7), at(0.15, 0.3), at(0.85, 0.3))
        a.overlay.moveCursor(to: startA, in: nil)
        a.overlay.settle(at: startA, in: nil)
        b.overlay.moveCursor(to: startB, in: nil)
        b.overlay.settle(at: startB, in: nil)

        let queued = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            a.withOverlay { $0.moveCursor(to: endA, in: nil) }
            a.withOverlay { $0.pulseClick(at: endA, clickCount: 1, mouseButton: .left, in: nil) }
            b.withOverlay { $0.moveCursor(to: endB, in: nil) }
            b.withOverlay { $0.pulseClick(at: endB, clickCount: 1, mouseButton: .left, in: nil) }
            queued.signal()
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 3), .success)

        var (lastA, lastB) = (a.overlay.tipPositionForTesting, b.overlay.tipPositionForTesting)
        var (aMoving, bMoving, bothMoving) = (false, false, 0)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, a.overlay.hasQueuedWorkForTesting || b.overlay.hasQueuedWorkForTesting || !(aMoving || bMoving) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let (tipA, tipB) = (a.overlay.tipPositionForTesting, b.overlay.tipPositionForTesting)
            aMoving = tipA != lastA
            bMoving = tipB != lastB
            if aMoving && bMoving { bothMoving += 1 }
            (lastA, lastB) = (tipA, tipB)
        }
        XCTAssertFalse(a.overlay.hasQueuedWorkForTesting || b.overlay.hasQueuedWorkForTesting, "both queues drain")
        XCTAssertGreaterThan(bothMoving, 5, "the two chats' cursors glide in the same frames")
        XCTAssertLessThan(abs((a.overlay.tipPositionForTesting?.x ?? 0) - endA.x), 3)
        XCTAssertLessThan(abs((b.overlay.tipPositionForTesting?.x ?? 0) - endB.x), 3)
    }
}

/// Renders the default cursor and every chat colour on light and dark backdrops:
/// set OCU_CURSOR_SWATCH_FILE to a .png path.
final class SessionCursorSwatchTests: XCTestCase {
    func testRenderSwatch() throws {
        guard let path = ProcessInfo.processInfo.environment["OCU_CURSOR_SWATCH_FILE"] else {
            throw XCTSkip("set OCU_CURSOR_SWATCH_FILE to render the colour swatch")
        }
        let tints: [NSColor?] = [nil] + visualCursorSessionTints
        let cell = SoftwareCursorGlyphMetrics.windowSize
        let size = CGSize(width: cell.width * CGFloat(tints.count), height: cell.height * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        let context = try XCTUnwrap(NSGraphicsContext.current?.cgContext)
        for (row, backdrop) in [NSColor(white: 0.96, alpha: 1), NSColor(white: 0.14, alpha: 1)].enumerated() {
            backdrop.setFill()
            CGRect(x: 0, y: CGFloat(row) * cell.height, width: size.width, height: cell.height).fill()
            for (column, tint) in tints.enumerated() {
                context.saveGState()
                context.translateBy(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height)
                // The cursor window is transparent; draw on a clear layer as the panel does.
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                SoftwareCursorGlyphRenderer.draw(
                    in: CGRect(origin: .zero, size: cell),
                    context: context,
                    state: SoftwareCursorGlyphRenderState(rotation: 0, cursorBodyOffset: .zero, fogOffset: .zero, fogOpacity: 0.12, fogScale: 1, clickProgress: 0),
                    tint: tint
                )
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        image.unlockFocus()
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
