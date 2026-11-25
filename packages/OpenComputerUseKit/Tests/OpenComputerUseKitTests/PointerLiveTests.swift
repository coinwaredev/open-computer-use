import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Drives SkyLight pointer input at a real window. Set OCU_LIVE_POINTER_PID to the pid
/// of an app whose first on-screen window should receive the events, and
/// OCU_LIVE_POINTER_STEPS to a comma list of hover, ldrag, rdrag, odrag, wheel.
final class PointerLiveTests: XCTestCase {
    func testSkyPointerInputReachesWindow() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["OCU_LIVE_POINTER_PID"], let pid = pid_t(raw) else {
            throw XCTSkip("set OCU_LIVE_POINTER_PID to drive a real window")
        }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let title = env["OCU_LIVE_POINTER_TITLE"]
        let window = try XCTUnwrap(info.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && (title == nil || (($0[kCGWindowName as String] as? String) ?? "").contains(title!))
        })
        let id = CGWindowID((window[kCGWindowNumber as String] as! NSNumber).uint32Value)
        let bounds = try XCTUnwrap(CGRect(dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary))
        let target = SkyPointerTarget(windowBounds: bounds, windowID: id, pid: pid)
        func point(_ fx: CGFloat, _ fy: CGFloat) -> SkyPointerPoint {
            let local = CGPoint(x: bounds.width * fx, y: bounds.height * fy)
            return SkyPointerPoint(screen: CGPoint(x: bounds.minX + local.x, y: bounds.minY + local.y), window: local)
        }
        let steps = (env["OCU_LIVE_POINTER_STEPS"] ?? "hover,ldrag,rdrag,odrag,wheel").split(separator: ",")
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mouseBefore = NSEvent.mouseLocation
        for step in steps {
            let start = Date()
            switch step {
            case "hover": try SkyPointerDispatcher.hover(at: point(0.3, 0.4), target: target)
            case "ldrag": try SkyPointerDispatcher.drag(button: .left, from: point(0.2, 0.5), to: point(0.6, 0.7), duration: 0.25, target: target)
            case "rdrag": try SkyPointerDispatcher.drag(button: .right, from: point(0.5, 0.5), to: point(0.8, 0.5), duration: 0.25, target: target)
            case "odrag": try SkyPointerDispatcher.drag(button: .middle, from: point(0.5, 0.5), to: point(0.5, 0.8), duration: 0.25, target: target)
            case "wheel": try SkyPointerDispatcher.scroll(at: point(0.5, 0.5), direction: "down", pages: 1, target: target)
            case "wheelup": try SkyPointerDispatcher.scroll(at: point(0.5, 0.5), direction: "up", pages: 1, target: target)
            default: XCTFail("unknown step \(step)")
            }
            print(String(format: "pointer live: %@ %.0f ms", String(step), Date().timeIntervalSince(start) * 1000))
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontBefore, "the target must not come to the front")
        XCTAssertEqual(NSEvent.mouseLocation, mouseBefore, "the real pointer must not move")
    }
}
