import AppKit
import CoreGraphics
import Foundation
import QuartzCore

/// Static entry points for the shared default cursor (one-shot CLI, tests). A chat's MCP session
/// draws its own cursor through its own `VisualCursorChannel`.
public enum VisualCursorSupport {
    static var generation: UInt64 { VisualCursorChannel.shared.generation }

    static func isCurrent(_ generation: UInt64) -> Bool { VisualCursorChannel.shared.isCurrent(generation) }

    static func invalidatePending() { VisualCursorChannel.shared.invalidatePending() }

    static func resetOnMain() { VisualCursorChannel.shared.resetOnMain() }

    public static var isEnabled: Bool {
        visualCursorEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func performOnMain(_ body: @escaping @MainActor () -> Void) {
        VisualCursorChannel.shared.performOnMain(body)
    }
}

/// One chat's cursor. Every MCP session in the App Agent gets its own, so chats running side by
/// side each draw their own pointer, in their own colour, and ending or resetting one chat leaves
/// the others alone. Upstream had one process-wide cursor: two chats flew it back and forth
/// between their targets, and any session end hid it for everyone.
public final class VisualCursorChannel: @unchecked Sendable {
    /// The default cursor: original colours, used by the one-shot CLI and tests.
    public static let shared = VisualCursorChannel(isSession: false, frames: CursorWindowFrameTracker.shared)

    let frames: CursorWindowFrames
    /// A session cursor takes the next colour when it is first drawn, so services that never draw
    /// (list_apps, a CLI snapshot) don't use one up.
    private let isSession: Bool
    private let lock = NSLock()
    private var generationValue: UInt64 = 0
    /// Main thread only.
    nonisolated(unsafe) private var overlayStorage: VisualCursor?

    init(isSession: Bool, frames: CursorWindowFrames = CursorWindowFrames()) {
        self.isSession = isSession
        self.frames = frames
        Self.registry.add(self)
    }

    /// A new chat's cursor, tinted with the next colour in `visualCursorSessionTints`.
    public static func makeSession() -> VisualCursorChannel {
        VisualCursorChannel(isSession: true)
    }

    deinit {
        nonisolated(unsafe) let overlay = overlayStorage
        guard overlay != nil else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { overlay?.teardown() }
        }
    }

    @MainActor var overlay: VisualCursor {
        if let overlayStorage { return overlayStorage }
        let tint = isSession ? visualCursorSessionTint(index: Self.registry.nextSessionIndex()) : nil
        let overlay = VisualCursor(channel: self, tint: tint)
        overlayStorage = overlay
        return overlay
    }

    var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generationValue
    }

    func isCurrent(_ generation: UInt64) -> Bool { self.generation == generation }

    func invalidatePending() {
        lock.lock(); defer { lock.unlock() }
        generationValue &+= 1
    }

    /// Invalidate queued work immediately, including the currently playing
    /// animation. Enqueue cleanup before any work from the next generation.
    func resetOnMain() {
        lock.lock()
        generationValue &+= 1
        if Thread.isMainThread {
            lock.unlock()
            MainActor.assumeIsolated { overlayStorage?.reset(invalidatePending: false) }
        } else {
            let generation = generationValue
            DispatchQueue.main.async { [self] in
                guard isCurrent(generation) else { return }
                MainActor.assumeIsolated { overlayStorage?.reset(invalidatePending: false) }
            }
            lock.unlock()
        }
    }

    /// Cursor animations are cosmetic, so an off-main caller (a tool call) does
    /// not wait for them. The main queue plays them in order: it does not start
    /// the next block while an animation pumps the run loop inside the current
    /// one. A backlog reaches `adaptiveCursorTempo` as a zero gap, so the cursor
    /// speeds up to catch up. A main-thread caller plays inline; the one-shot
    /// CLI, which calls on the main thread, draws nothing (`canPresentOverlay`).
    func performOnMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body()
            }
            return
        }

        lock.lock()
        let generation = generationValue
        DispatchQueue.main.async { [self] in
            guard isCurrent(generation) else { return }
            MainActor.assumeIsolated { body() }
        }
        lock.unlock()
    }

    /// `performOnMain` with this channel's overlay. A main-thread caller plays inline.
    /// Off-main work (a tool call) joins this cursor's own queue, which animates on the
    /// cursor's frame timer instead of holding the main queue, so one chat's glide never
    /// stalls another chat's cursor.
    func withOverlay(_ body: @escaping @MainActor (VisualCursor) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(overlay) }
            return
        }

        lock.lock()
        let generation = generationValue
        DispatchQueue.main.async { [self] in
            guard isCurrent(generation) else { return }
            MainActor.assumeIsolated {
                let cursor = overlay
                cursor.enqueue { [weak self] in
                    guard self?.isCurrent(generation) == true else { return }
                    body(cursor)
                }
            }
        }
        lock.unlock()
    }

    /// Every live cursor, for a host turn-ended notification, which names no session.
    static func resetAllOnMain() {
        for channel in registry.live() {
            channel.resetOnMain()
        }
    }

    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private final class WeakChannel { weak var channel: VisualCursorChannel?; init(_ channel: VisualCursorChannel) { self.channel = channel } }
        private let lock = NSLock()
        private var channels: [WeakChannel] = []
        private var sessions = 0

        func add(_ channel: VisualCursorChannel) {
            lock.lock(); defer { lock.unlock() }
            channels.removeAll { $0.channel == nil }
            channels.append(WeakChannel(channel))
        }

        func live() -> [VisualCursorChannel] {
            lock.lock(); defer { lock.unlock() }
            return channels.compactMap(\.channel)
        }

        func nextSessionIndex() -> Int {
            lock.lock(); defer { lock.unlock() }
            sessions += 1
            return sessions - 1
        }
    }
}

/// Session cursor colours, in the order chats connect; they repeat after the last.
let visualCursorSessionTints: [NSColor] = [
    NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.96, alpha: 1), // blue
    NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.12, alpha: 1), // orange
    NSColor(calibratedRed: 0.16, green: 0.70, blue: 0.36, alpha: 1), // green
    NSColor(calibratedRed: 0.90, green: 0.26, blue: 0.58, alpha: 1), // pink
    NSColor(calibratedRed: 0.56, green: 0.38, blue: 0.94, alpha: 1), // purple
    NSColor(calibratedRed: 0.06, green: 0.66, blue: 0.72, alpha: 1), // teal
]

func visualCursorSessionTint(index: Int) -> NSColor {
    visualCursorSessionTints[((index % visualCursorSessionTints.count) + visualCursorSessionTints.count) % visualCursorSessionTints.count]
}

func visualCursorEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_VISUAL_CURSOR"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return true
    }

    return !["0", "false", "no", "off"].contains(rawValue)
}

func visualCursorBurstFloor(environment: [String: String]) -> Double {
    guard let raw = environment["OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR"],
          let value = Double(raw), value.isFinite, value > 0 else { return 0.15 }
    return min(value, 1)
}

func defaultVisualCursorInitialTipPosition(
    windowOrigin: CGPoint = .zero,
    tipAnchor: CGPoint = SoftwareCursorGlyphMetrics.tipAnchor
) -> CGPoint {
    return CGPoint(
        x: windowOrigin.x + tipAnchor.x,
        y: windowOrigin.y + tipAnchor.y
    )
}

/// Where a cursor with no current position starts its first move. Upstream started every fresh
/// cursor at the screen origin (the bottom-left corner), so after each session end or 30 s idle
/// hide it flew in from that corner. Prefer where it was last seen, then the user's real pointer.
func visualCursorFreshStartTipPosition(
    lastSeen: CGPoint?,
    pointer: CGPoint?,
    fallback: CGPoint
) -> CGPoint {
    lastSeen ?? pointer ?? fallback
}

func visualCursorRenderBaseHeading(
    artworkNeutralHeading: CGFloat = SoftwareCursorGlyphMetrics.targetNeutralHeading
) -> CGFloat {
    artworkNeutralHeading
}

func visualCursorAppKitForwardHeading(
    renderRotation: CGFloat,
    artworkNeutralHeading: CGFloat = SoftwareCursorGlyphMetrics.targetNeutralHeading
) -> CGFloat {
    -artworkNeutralHeading - renderRotation
}

func visualCursorRuntimeRenderYAxisMultiplier() -> CGFloat {
    // Window placement uses AppKit global coordinates, but glyph render state is
    // still interpreted as CursorMotion's y-down screen state before drawing.
    -1
}

func visualCursorScreenStateVelocity(
    fromRuntimeVelocity velocity: CGVector,
    yAxisMultiplier: CGFloat
) -> CGVector {
    CGVector(dx: velocity.dx, dy: velocity.dy * yAxisMultiplier)
}

/// Tempo multiplier for the next cursor action: 1 when the cursor has been idle
/// for `relaxedGap`, shrinking toward `floor` as actions arrive back to back, the
/// way a hand speeds up through a burst of clicks. `gap` is the idle time since
/// the previous action finished.
func adaptiveCursorTempo(previous: Double, gap: TimeInterval, relaxedGap: TimeInterval = 2, floor: Double) -> Double {
    let calm = min(max(gap / relaxedGap, 0), 1)
    let recovered = previous + (1 - previous) * calm
    return max(min(floor, 1), recovered * (0.6 + 0.4 * calm))
}

/// How long a glide takes before the burst tempo: a quick flick like a hand on a mouse,
/// growing with the log of the distance (Fitts), about 0.2 s across a toolbar and 0.35 s
/// across a screen, never more than 0.4 s. The recovered official timing played every
/// glide over the full spring time (1.4 s), and a chat that pauses to think between
/// actions never sped it up, so the cursor reached each target long after the click.
/// OPEN_COMPUTER_USE_CURSOR_MOTION=classic keeps the official timing.
func visualCursorTravelDuration(
    distance: CGFloat,
    calibrated: CGFloat,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> CGFloat {
    if environment["OPEN_COMPUTER_USE_CURSOR_MOTION"]?.lowercased() == "classic" {
        return calibrated
    }
    let flick = 0.1 + 0.055 * log2(1 + max(distance, 0) / 30)
    return min(calibrated, min(max(flick, 0.12), 0.4))
}

/// Unit tests drive real cursor windows, some to the screen origin (the bottom-left
/// corner), on whatever screen runs them. Draw them blank there so a test run never
/// looks like a chat's cursor jumping around; OCU_TEST_SHOW_CURSOR=1 draws them.
let visualCursorBlankInTests = NSClassFromString("XCTestCase") != nil
    && ProcessInfo.processInfo.environment["OCU_TEST_SHOW_CURSOR"] != "1"

/// One click's press-and-release on the cursor. Was 0.16 s.
let visualCursorClickPulseDuration: TimeInterval = 0.1

func visualCursorPostInteractionIdleTimeout() -> TimeInterval {
    30
}

func visualCursorIdleRotationAmplitude() -> CGFloat {
    0.09
}

public struct VisualCursorObservationPoint: Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(point: CGPoint) {
        x = point.x
        y = point.y
    }
}

public struct VisualCursorObservationSnapshot: Codable, Sendable {
    public let phase: String
    public let tipPosition: VisualCursorObservationPoint?
    public let restingTipPosition: VisualCursorObservationPoint?
    public let rotation: Double?
    public let timestamp: Double

    public init(
        phase: String,
        tipPosition: CGPoint?,
        restingTipPosition: CGPoint?,
        rotation: CGFloat?,
        timestamp: CFTimeInterval
    ) {
        self.phase = phase
        self.tipPosition = tipPosition.map(VisualCursorObservationPoint.init(point:))
        self.restingTipPosition = restingTipPosition.map(VisualCursorObservationPoint.init(point:))
        self.rotation = rotation.map(Double.init)
        self.timestamp = timestamp
    }
}

struct VisualCursorIdlePose {
    let tipPosition: CGPoint
    let angleOffset: CGFloat
}

func visualCursorIdlePose(restingTipPosition: CGPoint, phase: CGFloat) -> VisualCursorIdlePose {
    VisualCursorIdlePose(
        tipPosition: restingTipPosition,
        angleOffset: sin(phase * 0.8) * visualCursorIdleRotationAmplitude()
    )
}

public func visualCursorObservationFileURL(environment: [String: String]) -> URL? {
    guard
        let rawPath = environment["OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !rawPath.isEmpty
    else {
        return nil
    }

    return URL(fileURLWithPath: rawPath)
}

public let openComputerUseTurnEndedNotificationName = Notification.Name("com.ifuryst.opencomputeruse.turn-ended")

public func postOpenComputerUseTurnEndedNotification() {
    DistributedNotificationCenter.default().postNotificationName(
        openComputerUseTurnEndedNotificationName,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

/// Resets every chat's cursor: the host's turn-ended notification doesn't say which chat it was.
public func resetOpenComputerUseVisualCursor() {
    VisualCursorChannel.resetAllOnMain()
}

struct CursorTargetWindow: Equatable, Sendable {
    let windowID: CGWindowID
    let layer: Int
}

struct CursorWindowGeometry {
    let windowSize: CGSize
    let tipAnchor: CGPoint

    func origin(forTipPosition tipPosition: CGPoint) -> CGPoint {
        CGPoint(
            x: tipPosition.x - tipAnchor.x,
            y: tipPosition.y - tipAnchor.y
        )
    }

    func tipPosition(forOrigin origin: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x + tipAnchor.x,
            y: origin.y + tipAnchor.y
        )
    }
}

private struct CursorArtwork {
    let geometry: CursorWindowGeometry
    static let active = CursorArtwork(
        geometry: CursorWindowGeometry(
            windowSize: SoftwareCursorGlyphMetrics.windowSize,
            tipAnchor: SoftwareCursorGlyphMetrics.tipAnchor
        ),
    )
}

/// The static API drives the shared default cursor; see `VisualCursorChannel`.
@MainActor
enum SoftwareCursorOverlay {
    static var shared: VisualCursor { VisualCursorChannel.shared.overlay }

    static func moveCursor(to targetPoint: CGPoint, in targetWindow: CursorTargetWindow?, anchor: CursorRestingAnchor? = nil) {
        shared.moveCursor(to: targetPoint, in: targetWindow, anchor: anchor)
    }

    static func pulseClick(at targetPoint: CGPoint, clickCount: Int, mouseButton: MouseButtonKind, in targetWindow: CursorTargetWindow?, anchor: CursorRestingAnchor? = nil) {
        shared.pulseClick(at: targetPoint, clickCount: clickCount, mouseButton: mouseButton, in: targetWindow, anchor: anchor)
    }

    static func settle(at targetPoint: CGPoint, in targetWindow: CursorTargetWindow?, anchor: CursorRestingAnchor? = nil) {
        shared.settle(at: targetPoint, in: targetWindow, anchor: anchor)
    }

    static func reset(invalidatePending: Bool = true) {
        shared.reset(invalidatePending: invalidatePending)
    }
}

/// One cursor on screen: its window, position, motion and timers.
@MainActor
final class VisualCursor {
    private weak var channel: VisualCursorChannel?
    private let frames: CursorWindowFrames
    private let tint: NSColor?

    init(channel: VisualCursorChannel, tint: NSColor?) {
        self.channel = channel
        frames = channel.frames
        self.tint = tint
    }

    private var currentGeneration: UInt64 { channel?.generation ?? 0 }

    /// Queued work belongs to the generation it was queued in; a channel that is gone has no current work.
    private func isCurrent(_ generation: UInt64) -> Bool { channel?.isCurrent(generation) ?? false }

    var tipPositionForTesting: CGPoint? { displayedTipPosition }
    var isOnScreenForTesting: Bool { panel?.isVisible ?? false }
    var tintForTesting: NSColor? { tint }

    /// The chat is gone: take the cursor off screen and stop its timers.
    func teardown() {
        cancelQueuedWork()
        stopIdleAnimation()
        cancelPendingHide()
        panel?.orderOut(nil)
        panel = nil
        cursorView = nil
    }

    // Queued chat work (see `VisualCursorChannel.withOverlay`). A job runs once the
    // previous one's animation ends; animations step on `frameTimer`, so the main
    // queue stays free for other cursors.
    private var pendingJobs: [() -> Void] = []
    private var activeLoop: (step: () -> Bool, finish: () -> Void)?
    private var frameTimer: Timer?
    private var runningQueuedJob = false

    func enqueue(_ job: @escaping () -> Void) {
        pendingJobs.append(job)
        drainJobs()
    }

    var hasQueuedWorkForTesting: Bool { activeLoop != nil || !pendingJobs.isEmpty }

    private func drainJobs() {
        while activeLoop == nil, !runningQueuedJob, !pendingJobs.isEmpty {
            runQueued(pendingJobs.removeFirst())
        }
    }

    private func runQueued(_ body: () -> Void) {
        runningQueuedJob = true
        defer { runningQueuedJob = false }
        body()
    }

    /// Plays a frame loop; `step` draws one frame and returns true while more follow.
    /// Inline for a main-thread caller, on this cursor's frame timer for queued work.
    private func play(_ step: @escaping () -> Bool, then finish: @escaping () -> Void) {
        guard runningQueuedJob else {
            while step() {
                pumpFrame()
            }
            finish()
            return
        }

        guard step() else {
            finish()
            return
        }
        activeLoop = (step, finish)
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.frameTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func frameTick() {
        guard let loop = activeLoop else {
            stopFrameTimer()
            drainJobs()
            return
        }
        if loop.step() { return }
        activeLoop = nil
        runQueued(loop.finish)
        if activeLoop == nil { stopFrameTimer() }
        drainJobs()
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func cancelQueuedWork() {
        pendingJobs.removeAll()
        activeLoop = nil
        stopFrameTimer()
    }

    private let artwork = CursorArtwork.active
    private let renderBaseHeading = visualCursorRenderBaseHeading()
    private let renderYAxisMultiplier = visualCursorRuntimeRenderYAxisMultiplier()
    private var panel: CursorPanel?
    private var cursorView: SoftwareCursorView?
    private var restingTipPosition: CGPoint?
    /// Survives hide and session reset so the next fresh move starts where the cursor was last seen.
    private var lastSeenTipPosition: CGPoint?
    private var displayedTipPosition: CGPoint?
    private var activeTargetWindow: CursorTargetWindow?
    /// Window frame the current target point was derived from; lets a move
    /// under the cursor be detected and re-derived instead of ignored.
    private var restingAnchor: CursorRestingAnchor?
    private var lastAnchorFrame: CGRect?
    private var visualDynamicsState: CursorVisualDynamicsState?
    private var idleTimer: Timer?
    private var hideTimer: Timer?
    private var idlePhase: CGFloat = 0
    private var idleTicks = 0
    private var observationPhase = "hidden"
    private var tempo: Double = 1
    private var lastInteractionEnd: CFTimeInterval?

    func moveCursor(
        to targetPoint: CGPoint,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        let generation = currentGeneration
        prepareWindowIfNeeded()
        stopIdleAnimation()
        cancelPendingHide()
        configureOrdering(relativeTo: targetWindow)

        adoptAnchor(anchor)
        lastAnchorFrame = anchor.flatMap { frames.liveFrame(for: $0.windowID) } ?? anchor?.windowBounds
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        let isFreshStart = displayedTipPosition == nil
        let startPoint = displayedTipPosition ?? visualCursorFreshStartTipPosition(
            lastSeen: lastSeenTipPosition,
            pointer: NSEvent.mouseLocation,
            fallback: defaultInitialTipPosition()
        )
        let now = CACurrentMediaTime()
        tempo = adaptiveCursorTempo(
            previous: tempo,
            gap: lastInteractionEnd.map { now - $0 } ?? .infinity,
            floor: burstTempoFloor
        )
        let finish = { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.lastInteractionEnd = CACurrentMediaTime()
        }

        observationPhase = "moving"
        panel?.alphaValue = 1
        if isFreshStart {
            visualDynamicsState = CursorVisualDynamicsAnimator.state(at: startPoint, time: CGFloat(dynamicsTime(at: now)))
            placeCursor(using: initialRenderState(at: startPoint), clickProgress: 0)
        } else {
            seedVisualDynamicsIfNeeded(at: startPoint, time: now)
            placeCursor(
                using: advanceVisualDynamics(
                    toward: startPoint,
                    at: now
                ),
                clickProgress: 0
            )
        }

        if distanceBetween(startPoint, constrainedTarget) > 2 {
            play(moveLoop(from: startPoint, to: constrainedTarget, relativeTo: targetWindow, generation: generation), then: finish)
        } else {
            finish()
        }
    }

    func pulseClick(
        at targetPoint: CGPoint,
        clickCount: Int,
        mouseButton: MouseButtonKind,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        let generation = currentGeneration
        configureOrdering(relativeTo: targetWindow)
        stopIdleAnimation()
        adoptAnchor(anchor)
        _ = reanchorIfWindowMoved()
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        let now = CACurrentMediaTime()
        seedVisualDynamicsIfNeeded(at: constrainedTarget, time: now)
        restingTipPosition = constrainedTarget
        observationPhase = "pulse"
        play(clickPulseLoop(at: constrainedTarget, clickCount: max(clickCount, 1), mouseButton: mouseButton, generation: generation)) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.lastInteractionEnd = CACurrentMediaTime()
            self.startIdleAnimation()
            self.scheduleHide(after: visualCursorPostInteractionIdleTimeout())
        }
    }

    func settle(
        at targetPoint: CGPoint,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        configureOrdering(relativeTo: targetWindow)
        adoptAnchor(anchor)
        _ = reanchorIfWindowMoved()
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        restingTipPosition = constrainedTarget
        observationPhase = "settling"
        placeCursor(
            using: advanceVisualDynamics(
                toward: constrainedTarget,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
        startIdleAnimation()
        scheduleHide(after: visualCursorPostInteractionIdleTimeout())
    }

    func reset(invalidatePending: Bool = true) {
        if invalidatePending { channel?.invalidatePending() }
        cancelQueuedWork()
        stopIdleAnimation()
        cancelPendingHide()
        lastSeenTipPosition = displayedTipPosition ?? restingTipPosition ?? lastSeenTipPosition
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
        restingAnchor = nil
        lastAnchorFrame = nil
        frames.forgetAll()
        visualDynamicsState = nil
        tempo = 1
        lastInteractionEnd = nil
        dynamicsClock = 0
        dynamicsClockWall = nil
        dynamicsRate = 1
        observationPhase = "hidden"
        writeObservationSnapshot(tipPosition: nil, rotation: nil)
        panel?.orderOut(nil)
    }

    /// Re-derive a target point that was computed from a snapshot taken before
    /// the window moved. Element frames are window-relative, so the anchored
    /// point follows the window instead of staying on the display it just left.
    private func liveTargetPoint(_ targetPoint: CGPoint, anchor: CursorRestingAnchor?) -> CGPoint {
        guard let anchor,
              let liveFrame = frames.liveFrame(for: anchor.windowID),
              let screenStatePoint = anchor.screenStatePoint(liveFrame: liveFrame)
        else {
            return targetPoint
        }

        return screenStatePointToAppKitGlobalPoint(
            fromScreenStatePoint: screenStatePoint,
            screenMappings: currentVisualCursorScreenMappings()
        )
    }

    private func adoptAnchor(_ anchor: CursorRestingAnchor?) {
        if restingAnchor != anchor {
            restingAnchor = anchor
            lastAnchorFrame = anchor?.windowBounds
        }
        if anchor == nil { frames.forgetAll() }
    }

    /// Relocate the visible tip, not just its spring target. Otherwise an old
    /// travel velocity can leave it on the previous display after reanchoring.
    @discardableResult
    private func reanchorIfWindowMoved() -> Bool {
        guard let anchor = restingAnchor,
              let liveFrame = frames.liveFrame(for: anchor.windowID),
              liveFrame != lastAnchorFrame,
              let screenStatePoint = anchor.screenStatePoint(liveFrame: liveFrame)
        else {
            return false
        }

        let constrainedTarget = clampTipPosition(
            screenStatePointToAppKitGlobalPoint(
                fromScreenStatePoint: screenStatePoint,
                screenMappings: currentVisualCursorScreenMappings()
            )
        )
        lastAnchorFrame = liveFrame
        restingTipPosition = constrainedTarget
        visualDynamicsState = CursorVisualDynamicsAnimator.state(at: constrainedTarget, time: CGFloat(dynamicsTime(at: CACurrentMediaTime())))
        observationPhase = "reanchored"
        placeCursor(
            using: initialRenderState(at: constrainedTarget),
            clickProgress: 0
        )
        return true
    }

    /// Only a process that made an NSApplication (MCP server, app agent) draws
    /// the cursor. A one-shot `call` makes none: its cursor would vanish when it
    /// exits, and played inline on the main thread it held the click until the
    /// glide ended.
    private var canPresentOverlay: Bool {
        NSApp != nil && !NSScreen.screens.isEmpty
    }

    private func prepareWindowIfNeeded() {
        guard panel == nil else {
            return
        }

        let panel = CursorPanel(
            contentRect: CGRect(origin: .zero, size: artwork.geometry.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none

        let view = SoftwareCursorView(frame: CGRect(origin: .zero, size: artwork.geometry.windowSize))
        view.tint = tint
        view.isHidden = visualCursorBlankInTests
        panel.contentView = view

        self.panel = panel
        self.cursorView = view
    }

    private func configureOrdering(relativeTo targetWindow: CursorTargetWindow?) {
        configureOrdering(relativeTo: targetWindow, forceReorder: false)
    }

    private func configureOrdering(relativeTo targetWindow: CursorTargetWindow?, forceReorder: Bool) {
        guard let panel else {
            return
        }

        let effectiveTargetWindow = targetWindow.flatMap { targetWindow in
            isWindowPresent(targetWindow.windowID) ? targetWindow : nil
        }

        let desiredLevel = NSWindow.Level(rawValue: effectiveTargetWindow?.layer ?? 0)
        if panel.level != desiredLevel {
            panel.level = desiredLevel
        }

        if shouldReorderCursorPanel(
            activeTargetWindow: activeTargetWindow,
            effectiveTargetWindow: effectiveTargetWindow,
            panelIsVisible: panel.isVisible,
            forceReorder: forceReorder
        ) {
            if let effectiveTargetWindow {
                panel.order(.above, relativeTo: Int(effectiveTargetWindow.windowID))
            } else {
                panel.orderFront(nil)
            }
            activeTargetWindow = effectiveTargetWindow
        }
    }

    /// Lowest tempo a burst of back-to-back actions can reach (see
    /// `adaptiveCursorTempo`). Default 0.15; OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR
    /// overrides it, 1 turns the speed-up off.
    let burstTempoFloor = visualCursorBurstFloor(environment: ProcessInfo.processInfo.environment)

    // The drawn tip follows the path through the visual-dynamics springs. Those
    // run on this clock, not wall time: while a move or pulse plays it advances
    // 1 / tempo times faster, so a sped-up animation is the full-length one
    // played faster and still lands on the target. On wall time the springs
    // trail a sped-up glide, so the click pulse starts short of the target.
    private var dynamicsClock: CFTimeInterval = 0
    private var dynamicsClockWall: CFTimeInterval?
    private var dynamicsRate: Double = 1

    private func dynamicsTime(at wall: CFTimeInterval) -> CFTimeInterval {
        if let last = dynamicsClockWall {
            dynamicsClock += max(0, wall - last) * dynamicsRate
        }
        dynamicsClockWall = wall
        return dynamicsClock
    }

    private func paceDynamics(_ paced: Bool, tempo pacedTempo: Double? = nil) {
        _ = dynamicsTime(at: CACurrentMediaTime())
        dynamicsRate = paced ? 1 / max(pacedTempo ?? tempo, 0.001) : 1
    }

    private func moveLoop(from start: CGPoint, to end: CGPoint, relativeTo targetWindow: CursorTargetWindow?, generation: UInt64) -> () -> Bool {
        let candidate = bestMotionCandidate(from: start, to: end, relativeTo: targetWindow)
        let path = candidate.path
        // The recovered official spring shape, played over a hand-speed duration (see
        // `visualCursorTravelDuration`). The springs run on the paced clock, so a faster
        // glide is the same motion played faster and still lands on the target.
        let calibrated = OfficialCursorMotionModel.calibratedTravelDuration(
            distance: distanceBetween(start, end),
            measurement: candidate.measurement
        )
        let travel = visualCursorTravelDuration(distance: distanceBetween(start, end), calibrated: calibrated)
        let travelTempo = tempo * Double(travel / max(calibrated, 0.001))
        let duration = calibrated * CGFloat(travelTempo)
        let springTargetDuration = OfficialCursorMotionModel.closeEnoughTime
        paceDynamics(true, tempo: travelTempo)
        let startTime = CACurrentMediaTime()
        var progress: CGFloat = 0
        var springState = CursorMotionSpringState()

        return { [weak self] in
            guard let self else { return false }
            guard self.isCurrent(generation) else {
                self.paceDynamics(false)
                return false
            }
            self.refreshActiveOrderingIfNeeded()

            if self.reanchorIfWindowMoved() {
                self.paceDynamics(false)
                return false
            }

            let elapsed = CGFloat(CACurrentMediaTime() - startTime)
            let normalizedElapsed = (elapsed / max(duration, 0.001)).clamped(to: 0...1)
            let springTime = normalizedElapsed * springTargetDuration
            (progress, springState) = CursorMotionProgressAnimator.advance(
                current: progress,
                state: springState,
                to: springTime
            )

            let sample = path.sample(at: progress)
            self.placeCursor(
                using: self.advanceVisualDynamics(
                    toward: sample.point,
                    at: CACurrentMediaTime()
                ),
                clickProgress: 0
            )

            if normalizedElapsed < 1, !CursorMotionProgressAnimator.isCloseEnough(progress: progress) {
                return true
            }

            self.paceDynamics(false)
            self.placeCursor(
                using: self.advanceVisualDynamics(
                    toward: end,
                    at: CACurrentMediaTime()
                ),
                clickProgress: 0
            )
            return false
        }
    }

    private func bestMotionCandidate(from start: CGPoint, to end: CGPoint, relativeTo targetWindow: CursorTargetWindow?) -> CursorMotionCandidate {
        let bounds = motionBounds(from: start, to: end)
        let candidates = HeadingDrivenCursorMotionModel.makeCandidates(
            start: start,
            end: end,
            bounds: bounds,
            startForward: currentForwardVector(),
            endForward: restingForwardVector()
        )
        let defaultCandidate = HeadingDrivenCursorMotionModel.chooseBestCandidate(from: candidates)
            ?? CursorMotionCandidate(
                identifier: "legacy-fallback",
                kind: .base,
                side: 0,
                tableAScale: nil,
                tableBScale: nil,
                path: CursorMotionPath(start: start, end: end),
                measurement: CursorMotionPath(start: start, end: end).measure(bounds: bounds),
                score: 0
            )

        guard let targetWindow else {
            return defaultCandidate
        }

        let excludingWindowNumber = max(panel?.windowNumber ?? 0, 0)
        let evaluations = candidates.map { candidate in
            (
                candidate: candidate,
                hitCount: windowConstraintHitCount(
                    for: candidate.path,
                    relativeTo: targetWindow,
                    excludingWindowNumber: excludingWindowNumber
                )
            )
        }

        let totalSampleCount = candidates.first?.path.sampledConstraintPoints().count ?? 0
        let bestHitCount = evaluations.map(\.hitCount).max() ?? 0

        if bestHitCount == totalSampleCount, bestHitCount > 0 {
            return evaluations
                .filter { $0.hitCount == bestHitCount }
                .map(\.candidate)
                .sorted(by: candidatePreference)
                .first ?? defaultCandidate
        }

        if bestHitCount > 0 {
            return evaluations
                .filter { $0.hitCount == bestHitCount }
                .map(\.candidate)
                .sorted(by: candidatePreference)
                .first ?? defaultCandidate
        }

        return defaultCandidate
    }

    private func currentForwardVector() -> CGVector {
        let renderRotation = cursorView?.rotation ?? 0
        return forwardVector(renderRotation: renderRotation)
    }

    private func restingForwardVector() -> CGVector {
        forwardVector(renderRotation: 0)
    }

    private func forwardVector(renderRotation: CGFloat) -> CGVector {
        let angle = visualCursorAppKitForwardHeading(renderRotation: renderRotation)
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    private func windowConstraintHitCount(
        for path: CursorMotionPath,
        relativeTo targetWindow: CursorTargetWindow,
        excludingWindowNumber: Int
    ) -> Int {
        path.sampledConstraintPoints().reduce(into: 0) { result, point in
            if windowID(at: point, excludingWindowNumber: excludingWindowNumber) == targetWindow.windowID {
                result += 1
            }
        }
    }

    private func motionBounds(from start: CGPoint, to end: CGPoint) -> CGRect? {
        let startScreen = screen(containing: start) ?? NSScreen.main ?? NSScreen.screens.first
        let endScreen = screen(containing: end) ?? startScreen

        switch (startScreen, endScreen) {
        case let (startScreen?, endScreen?) where startScreen === endScreen:
            return startScreen.visibleFrame
        case let (startScreen?, endScreen?):
            return startScreen.visibleFrame.union(endScreen.visibleFrame)
        case let (screen?, nil), let (nil, screen?):
            return screen.visibleFrame
        default:
            return nil
        }
    }

    private func candidatePreference(_ lhs: CursorMotionCandidate, _ rhs: CursorMotionCandidate) -> Bool {
        if lhs.measurement.staysInBounds != rhs.measurement.staysInBounds {
            return lhs.measurement.staysInBounds && !rhs.measurement.staysInBounds
        }
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        return lhs.identifier < rhs.identifier
    }

    private func windowID(at point: CGPoint, excludingWindowNumber: Int) -> CGWindowID? {
        let windowNumber = NSWindow.windowNumber(
            at: NSPoint(x: point.x, y: point.y),
            belowWindowWithWindowNumber: excludingWindowNumber
        )

        guard windowNumber > 0 else {
            return nil
        }

        return CGWindowID(windowNumber)
    }

    private func isWindowPresent(_ windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        else {
            return false
        }

        return !windowInfo.isEmpty
    }

    private func refreshActiveOrderingIfNeeded() {
        guard let activeTargetWindow else {
            return
        }

        if isWindowPresent(activeTargetWindow.windowID) {
            configureOrdering(relativeTo: activeTargetWindow, forceReorder: true)
            return
        }

        configureOrdering(relativeTo: nil)
    }

    private func clickPulseLoop(at point: CGPoint, clickCount: Int, mouseButton: MouseButtonKind, generation: UInt64) -> () -> Bool {
        let pulseBias: CGFloat = mouseButton == .right ? 0.82 : 1
        paceDynamics(true)
        var pulse = 0
        var pausing = false
        var phaseStart = CACurrentMediaTime()

        return { [weak self] in
            guard let self else { return false }
            guard self.isCurrent(generation) else {
                self.paceDynamics(false)
                return false
            }

            let now = CACurrentMediaTime()
            if pausing {
                if now - phaseStart < 0.05 * self.tempo { return true }
                pausing = false
                phaseStart = now
            }

            _ = self.reanchorIfWindowMoved()
            let rawProgress = min(max((now - phaseStart) / (visualCursorClickPulseDuration * self.tempo), 0), 1)
            self.placeCursor(
                using: self.advanceVisualDynamics(
                    toward: self.restingTipPosition ?? point,
                    at: CACurrentMediaTime()
                ),
                clickProgress: sin(rawProgress * .pi) * pulseBias
            )
            if rawProgress < 1 { return true }

            pulse += 1
            if pulse < clickCount {
                pausing = true
                phaseStart = CACurrentMediaTime()
                return true
            }

            self.paceDynamics(false)
            self.placeCursor(
                using: self.advanceVisualDynamics(
                    toward: self.restingTipPosition ?? point,
                    at: CACurrentMediaTime()
                ),
                clickProgress: 0
            )
            return false
        }
    }

    private func startIdleAnimation() {
        stopIdleAnimation()
        guard canPresentOverlay, let restingTipPosition else {
            return
        }

        observationPhase = "idle"
        idlePhase = 0
        idleTicks = 0
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.idleTick()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer

        placeCursor(
            using: advanceVisualDynamics(
                toward: restingTipPosition,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
    }

    private func idleTick() {
        guard panel != nil, cursorView != nil else {
            return
        }

        // A refresh is three window-server round trips; every frame they were most of
        // the sway's cost. At 10 Hz the cursor is back above a raised target window
        // within 0.1 s.
        idleTicks += 1
        if idleTicks % 6 == 0 {
            refreshActiveOrderingIfNeeded()
        }
        _ = reanchorIfWindowMoved()
        guard let currentTipPosition = restingTipPosition else { return }

        observationPhase = "idle"
        idlePhase += 0.05
        let idlePose = visualCursorIdlePose(
            restingTipPosition: currentTipPosition,
            phase: idlePhase
        )

        placeCursor(
            using: advanceVisualDynamics(
                toward: idlePose.tipPosition,
                idleAngleOffset: idlePose.angleOffset,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
    }

    private func stopIdleAnimation() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func scheduleHide(after delay: TimeInterval) {
        cancelPendingHide()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideOverlay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func cancelPendingHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func hideOverlay() {
        guard let panel else {
            return
        }

        stopIdleAnimation()
        cancelPendingHide()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishHide(panel)
            }
        }
    }

    private func finishHide(_ panel: NSPanel) {
        panel.orderOut(nil)
        panel.alphaValue = 1
        lastSeenTipPosition = displayedTipPosition ?? restingTipPosition ?? lastSeenTipPosition
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
        restingAnchor = nil
        lastAnchorFrame = nil
        frames.forgetAll()
        visualDynamicsState = nil
        observationPhase = "hidden"
        writeObservationSnapshot(tipPosition: nil, rotation: nil)
    }

    private func defaultInitialTipPosition() -> CGPoint {
        defaultVisualCursorInitialTipPosition(
            windowOrigin: .zero,
            tipAnchor: artwork.geometry.tipAnchor
        )
    }

    private func initialRenderState(at tipPosition: CGPoint) -> CursorVisualRenderState {
        CursorVisualRenderState(
            tipPosition: tipPosition,
            rotation: 0,
            cursorBodyOffset: CGVector(dx: 0, dy: 0),
            fogOffset: CGVector(dx: 0, dy: 0),
            fogOpacity: CursorVisualDynamicsConfiguration.officialInspired.fogOpacityBase,
            fogScale: 1
        )
    }

    private func seedVisualDynamicsIfNeeded(at tipPosition: CGPoint, time: CFTimeInterval) {
        guard visualDynamicsState == nil else {
            return
        }

        visualDynamicsState = CursorVisualDynamicsAnimator.state(
            at: tipPosition,
            time: CGFloat(dynamicsTime(at: time))
        )
    }

    private func advanceVisualDynamics(
        toward targetTipPosition: CGPoint,
        idleAngleOffset: CGFloat = 0,
        at time: CFTimeInterval
    ) -> CursorVisualRenderState {
        let clampedTarget = clampTipPosition(targetTipPosition)
        seedVisualDynamicsIfNeeded(at: clampedTarget, time: time)
        let time = dynamicsTime(at: time)

        let result = CursorVisualDynamicsAnimator.advance(
            state: visualDynamicsState ?? CursorVisualDynamicsAnimator.state(at: clampedTarget, time: CGFloat(time)),
            targetTipPosition: clampedTarget,
            targetTime: CGFloat(time),
            idleAngleOffset: idleAngleOffset,
            baseHeading: renderBaseHeading,
            renderYAxisMultiplier: renderYAxisMultiplier
        )
        visualDynamicsState = result.state
        return result.renderState
    }

    private func placeCursor(using renderState: CursorVisualRenderState, clickProgress: CGFloat) {
        guard let panel, let cursorView else {
            return
        }

        panel.setFrameOrigin(artwork.geometry.origin(forTipPosition: renderState.tipPosition))
        cursorView.rotation = renderState.rotation
        cursorView.cursorBodyOffset = renderState.cursorBodyOffset
        cursorView.fogOffset = renderState.fogOffset
        cursorView.fogOpacity = renderState.fogOpacity
        cursorView.fogScale = renderState.fogScale
        cursorView.clickProgress = clickProgress
        cursorView.needsDisplay = true
        displayedTipPosition = renderState.tipPosition
        writeObservationSnapshot(
            tipPosition: renderState.tipPosition,
            rotation: renderState.rotation
        )
    }

    private func writeObservationSnapshot(tipPosition: CGPoint?, rotation: CGFloat?) {
        // Every frame: copying the whole environment only to find the variable unset was not free.
        guard
            getenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE") != nil,
            let url = visualCursorObservationFileURL(environment: ProcessInfo.processInfo.environment)
        else {
            return
        }

        let snapshot = VisualCursorObservationSnapshot(
            phase: observationPhase,
            tipPosition: tipPosition,
            restingTipPosition: restingTipPosition,
            rotation: rotation,
            timestamp: CACurrentMediaTime()
        )

        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Observation is debug-only and must not affect tool execution.
        }
    }

    private func clampTipPosition(_ tipPosition: CGPoint) -> CGPoint {
        guard let screen = screen(containing: tipPosition) ?? NSScreen.main ?? NSScreen.screens.first else {
            return tipPosition
        }

        let visibleFrame = screen.visibleFrame
        let minX = visibleFrame.minX + artwork.geometry.tipAnchor.x
        let maxX = visibleFrame.maxX - (artwork.geometry.windowSize.width - artwork.geometry.tipAnchor.x)
        let minY = visibleFrame.minY + artwork.geometry.tipAnchor.y
        let maxY = visibleFrame.maxY - (artwork.geometry.windowSize.height - artwork.geometry.tipAnchor.y)

        return CGPoint(
            x: tipPosition.x.clamped(to: minX...maxX),
            y: tipPosition.y.clamped(to: minY...maxY)
        )
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func pumpFrame() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1 / 120))
    }

    private func distanceBetween(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}

func shouldReorderCursorPanel(
    activeTargetWindow: CursorTargetWindow?,
    effectiveTargetWindow: CursorTargetWindow?,
    panelIsVisible: Bool,
    forceReorder: Bool
) -> Bool {
    forceReorder || activeTargetWindow != effectiveTargetWindow || panelIsVisible == false
}

private final class CursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SoftwareCursorView: NSView {
    var rotation: CGFloat = 0
    var cursorBodyOffset: CGVector = CGVector(dx: 0, dy: 0)
    var fogOffset: CGVector = CGVector(dx: 0, dy: 0)
    var fogOpacity: CGFloat = 0.12
    var fogScale: CGFloat = 1
    var clickProgress: CGFloat = 0
    var tint: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        SoftwareCursorGlyphRenderer.draw(
            in: bounds,
            context: context,
            state: SoftwareCursorGlyphRenderState(
                rotation: rotation,
                cursorBodyOffset: cursorBodyOffset,
                fogOffset: fogOffset,
                fogOpacity: fogOpacity,
                fogScale: fogScale,
                clickProgress: clickProgress
            ),
            tint: tint
        )
    }
}
