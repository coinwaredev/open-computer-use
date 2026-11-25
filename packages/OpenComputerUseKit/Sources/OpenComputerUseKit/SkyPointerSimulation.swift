import AppKit
import CoreGraphics
import Foundation

/// One pointer position, in both coordinate spaces a SkyLight mouse event carries:
/// the global screen point and the point inside the target window.
struct SkyPointerPoint: Equatable {
    let screen: CGPoint
    let window: CGPoint
}

struct SkyPointerTarget {
    let windowBounds: CGRect
    let windowID: CGWindowID
    let pid: pid_t
}

/// Straight-line drag path, start excluded and end included, so each point is one
/// dragged event.
func skyDragPath(from start: SkyPointerPoint, to end: SkyPointerPoint, steps: Int) -> [SkyPointerPoint] {
    let count = max(steps, 1)
    return (1...count).map { step in
        let progress = CGFloat(step) / CGFloat(count)
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
        }
        return SkyPointerPoint(screen: lerp(start.screen, end.screen), window: lerp(start.window, end.window))
    }
}

/// Wheel ticks for a scroll of `pages` (12 lines a page, as the element scroll path
/// uses). A game view zooms once per wheel event, so the distance goes out as
/// notches of at most 3 lines instead of one large event. Positive wheel1 scrolls
/// up, positive wheel2 scrolls left.
func skyScrollTicks(direction: String, pages: Double) -> [(wheel1: Int32, wheel2: Int32)] {
    let total = Int(min(1200, max(1, (12.0 * pages).rounded(.toNearestOrAwayFromZero))))
    var ticks: [(Int32, Int32)] = []
    var left = total
    while left > 0 {
        let lines = Int32(min(3, left))
        left -= Int(lines)
        switch direction {
        case "up": ticks.append((lines, 0))
        case "down": ticks.append((-lines, 0))
        case "left": ticks.append((0, lines))
        default: ticks.append((0, -lines))
        }
    }
    return ticks
}

struct SkyPointerSideEffects: Equatable {
    var restoredPointer = false
    var targetTookFront = false
    var restoredFrontApp = false
}

/// Whether the real pointer jumped onto one of the points a drag sent: the target
/// warped it there (mouse lock). A pointer that moved anywhere else was the user's.
func pointerWasWarpedOntoPath(before: CGPoint, now: CGPoint, sent: [CGPoint]) -> Bool {
    guard hypot(now.x - before.x, now.y - before.y) > 1 else { return false }
    return sent.contains { hypot(now.x - $0.x, now.y - $0.y) <= 2 }
}

/// Background pointer input through SkyLight: hover, drags with any button, and
/// wheel events at a point. Each event is stamped with the target window the way
/// `SkyClickDispatcher` stamps clicks, so the window takes it without being raised
/// and the real pointer never moves. Game views (Roblox Studio's viewport) read
/// these: a right drag turns the camera, the wheel zooms.
enum SkyPointerDispatcher {
    private static let primerScreenPoint = CGPoint(x: -1, y: -1)
    private static let dispatchLock = NSLock()

    private enum EventField {
        static let mouseEventNumber: UInt32 = 0
        static let clickState: UInt32 = 1
        static let buttonNumber: UInt32 = 3
        static let subtype: UInt32 = 7
        static let targetPID: UInt32 = 40
        static let windowNumber: UInt32 = 51
        static let clickGroupID: UInt32 = 58
        static let windowUnderPointer: UInt32 = 91
        static let handlingWindowUnderPointer: UInt32 = 92
    }

    static func hover(at point: SkyPointerPoint, target: SkyPointerTarget, spi: SkyLightSPI = .shared) throws {
        try validate(point: point, target: target)
        try run(target: target, focus: false, spi: spi) { source, groupID in
            // Two moves, the first a pixel off: tracking areas fire on a change of
            // position, and a single event at the last-known spot can be a no-op.
            let nudge = SkyPointerPoint(
                screen: CGPoint(x: point.screen.x - 1, y: point.screen.y - 1),
                window: CGPoint(x: point.window.x - 1, y: point.window.y - 1)
            )
            try post(.mouseMoved, button: .left, at: nudge, target: target, source: source, number: 2, clickState: 0, groupID: groupID, spi: spi)
            pause(0.016)
            try post(.mouseMoved, button: .left, at: point, target: target, source: source, number: 2, clickState: 0, groupID: groupID, spi: spi)
        }
    }

    static func drag(
        button: MouseButtonKind,
        from start: SkyPointerPoint,
        to end: SkyPointerPoint,
        duration: TimeInterval,
        target: SkyPointerTarget,
        spi: SkyLightSPI = .shared
    ) throws -> SkyPointerSideEffects {
        try validate(point: start, target: target)
        try validate(point: end, target: target)
        let path = skyDragPath(from: start, to: end, steps: InputSimulation.dragStepCount(from: start.screen, to: end.screen))
        let interval = max(0.004, duration / Double(path.count))
        let pointerBefore = CGEvent(source: nil)?.location
        let frontBefore = NSWorkspace.shared.frontmostApplication

        try run(target: target, focus: true, spi: spi) { source, groupID in
            try post(.mouseMoved, button: button, at: start, target: target, source: source, number: 2, clickState: 0, groupID: groupID, spi: spi)
            pause(0.016)
            try post(button.downEvent, button: button, at: start, target: target, source: source, number: 3, clickState: 1, groupID: groupID, spi: spi)
            var last = start
            do {
                pause(0.03)
                for point in path {
                    // Whole-pixel steps between rounded positions, so the deltas add up to
                    // the full distance (a camera turn reads the deltas, not the position).
                    let delta = CGSize(
                        width: point.screen.x.rounded() - last.screen.x.rounded(),
                        height: point.screen.y.rounded() - last.screen.y.rounded()
                    )
                    try post(button.draggedEvent, button: button, at: point, target: target, source: source, number: 3, clickState: 1, groupID: groupID, delta: delta, spi: spi)
                    last = point
                    pause(interval)
                }
            } catch {
                // Never leave the button held in the target app.
                try? post(button.upEvent, button: button, at: last, target: target, source: source, number: 3, clickState: 1, groupID: groupID, checkSession: false, spi: spi)
                throw error
            }
            try post(button.upEvent, button: button, at: last, target: target, source: source, number: 3, clickState: 1, groupID: groupID, checkSession: false, spi: spi)
        }
        return undoTargetSideEffects(
            pointerBefore: pointerBefore,
            sentPoints: [start.screen] + path.map(\.screen),
            frontBefore: frontBefore,
            targetPID: target.pid
        )
    }

    /// A game that locks the mouse for a camera turn (Roblox on a right drag) warps
    /// the real pointer to where the button went down, and can take the foreground.
    /// Put both back. The pointer is moved only when it now sits on a point this drag
    /// sent, so a pointer the user moved meanwhile is left alone.
    private static func undoTargetSideEffects(
        pointerBefore: CGPoint?,
        sentPoints: [CGPoint],
        frontBefore: NSRunningApplication?,
        targetPID: pid_t
    ) -> SkyPointerSideEffects {
        var effects = SkyPointerSideEffects()
        if let pointerBefore, let now = CGEvent(source: nil)?.location,
           pointerWasWarpedOntoPath(before: pointerBefore, now: now, sent: sentPoints) {
            CGWarpMouseCursorPosition(pointerBefore)
            CGAssociateMouseAndMouseCursorPosition(1)
            effects.restoredPointer = true
        }
        if let frontBefore, frontBefore.processIdentifier != targetPID, !frontBefore.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
            effects.restoredFrontApp = frontBefore.activate(options: [])
            effects.targetTookFront = true
        }
        return effects
    }

    static func scroll(at point: SkyPointerPoint, direction: String, pages: Double, target: SkyPointerTarget, spi: SkyLightSPI = .shared) throws {
        try validate(point: point, target: target)
        try run(target: target, focus: false, spi: spi) { source, groupID in
            try post(.mouseMoved, button: .left, at: point, target: target, source: source, number: 2, clickState: 0, groupID: groupID, spi: spi)
            pause(0.016)
            for tick in skyScrollTicks(direction: direction, pages: pages) {
                try requireUsableComputerUseSession()
                guard let event = CGEvent(
                    scrollWheelEvent2Source: source,
                    units: .line,
                    wheelCount: 2,
                    wheel1: tick.wheel1,
                    wheel2: tick.wheel2,
                    wheel3: 0
                ) else {
                    throw ComputerUseError.message("Failed to create SkyLight scroll event.")
                }
                event.location = point.screen
                try stampWindow(event, point: point, target: target, spi: spi)
                try deliver(event, pid: target.pid, spi: spi)
                pause(0.016)
            }
        }
    }

    // MARK: - Plumbing

    private static func run(
        target: SkyPointerTarget,
        focus: Bool,
        spi: SkyLightSPI,
        body: (CGEventSource, Int64) throws -> Void
    ) throws {
        try requireUsableComputerUseSession()
        guard spi.capability.isAvailable else {
            throw ComputerUseError.message("SkyLight pointer input is unavailable: \(spi.capability.unavailableReason)")
        }
        try validateWindow(target: target)

        dispatchLock.lock()
        defer { dispatchLock.unlock() }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create SkyLight HID event source.")
        }
        let groupID = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)

        // A background Cocoa window takes a press only while it believes its app is
        // active (see `SkyClickDispatcher`). Hover and the wheel need no press.
        var focusContext: SkyLightSyntheticFocusContext?
        if focus, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
            focusContext = try spi.beginSyntheticTargetFocus(targetPID: target.pid, targetWindowID: target.windowID)
        }
        defer {
            if let focusContext {
                pause(0.1)
                try? spi.endSyntheticTargetFocus(focusContext)
            }
        }
        try body(source, groupID)
    }

    private static func post(
        _ type: CGEventType,
        button: MouseButtonKind,
        at point: SkyPointerPoint,
        target: SkyPointerTarget,
        source: CGEventSource,
        number: Int64,
        clickState: Int64,
        groupID: Int64,
        delta: CGSize? = nil,
        checkSession: Bool = true,
        spi: SkyLightSPI
    ) throws {
        if checkSession { try requireUsableComputerUseSession() }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point.screen, mouseButton: button.cgButton) else {
            throw ComputerUseError.message("Failed to create SkyLight mouse event \(type.rawValue).")
        }
        try spi.setIntegerField(event, field: EventField.mouseEventNumber, value: number)
        try spi.setIntegerField(event, field: EventField.clickState, value: clickState)
        try spi.setIntegerField(event, field: EventField.buttonNumber, value: Int64(button.cgButton.rawValue))
        try spi.setIntegerField(event, field: EventField.subtype, value: 3)
        try spi.setIntegerField(event, field: EventField.clickGroupID, value: groupID)
        if let delta {
            let dx = Int64(delta.width.rounded())
            let dy = Int64(delta.height.rounded())
            event.setIntegerValueField(.mouseEventDeltaX, value: dx)
            event.setIntegerValueField(.mouseEventDeltaY, value: dy)
            event.setDoubleValueField(.mouseEventDeltaX, value: Double(delta.width))
            event.setDoubleValueField(.mouseEventDeltaY, value: Double(delta.height))
        }
        try stampWindow(event, point: point, target: target, spi: spi)
        try deliver(event, pid: target.pid, spi: spi)
    }

    private static func stampWindow(_ event: CGEvent, point: SkyPointerPoint, target: SkyPointerTarget, spi: SkyLightSPI) throws {
        let windowID = Int64(target.windowID)
        try spi.setIntegerField(event, field: EventField.targetPID, value: Int64(target.pid))
        try spi.setIntegerField(event, field: EventField.windowNumber, value: windowID)
        try spi.setIntegerField(event, field: EventField.windowUnderPointer, value: windowID)
        try spi.setIntegerField(event, field: EventField.handlingWindowUnderPointer, value: windowID)
        try spi.setWindowLocation(event, point: point.window)
    }

    /// SkyLight only, unlike `SkyClickDispatcher`'s dual post: a drag or wheel
    /// event posted through both channels can reach the app twice.
    private static func deliver(_ event: CGEvent, pid: pid_t, spi: SkyLightSPI) throws {
        try spi.postToPid(event, pid: pid)
    }

    private static func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func validate(point: SkyPointerPoint, target: SkyPointerTarget) throws {
        guard point.screen.x.isFinite, point.screen.y.isFinite, point.window.x.isFinite, point.window.y.isFinite else {
            throw ComputerUseError.message("SkyLight pointer input requires finite coordinates")
        }
        guard CGRect(origin: .zero, size: target.windowBounds.size).contains(point.window) else {
            throw ComputerUseError.message("SkyLight pointer target is outside the snapshot window bounds")
        }
    }

    private static func validateWindow(target: SkyPointerTarget) throws {
        guard target.windowBounds.width > 0, target.windowBounds.height > 0 else {
            throw ComputerUseError.message("SkyLight pointer input requires the target window bounds")
        }
        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true {
            throw ComputerUseError.stateUnavailable("The target app is hidden. Unhide it first.")
        }
        let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        guard skyClickWindowMatchesTarget(windowInfo: windowInfo, windowID: target.windowID, pid: target.pid) else {
            throw ComputerUseError.stateUnavailable("The target window no longer exists. Run get_app_state again.")
        }
    }
}
