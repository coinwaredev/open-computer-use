import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One step of a `key_sequence` call.
public enum KeySequenceStep: Equatable, Sendable {
    /// Hold a single key (or a modifier such as `shift`) down until a later `up`, or the end of the sequence.
    case down(String)
    /// Release a key an earlier `down` is holding.
    case up(String)
    /// Tap a key or chord (`press_key` syntax) while any held keys stay down.
    case press(String)
    /// Wait while held keys stay down.
    case wait(milliseconds: Double)
}

/// A timeline of key-downs, key-ups, taps and waits, delivered to one app in one call so keys can
/// overlap: hold W, tap Space, keep walking. Games read held keys every frame, so walking while
/// jumping needs both keys down at once, which separate `press_key` calls cannot do.
///
/// The whole sequence is validated before anything is sent, and every key still held at the end is
/// released, including when delivery fails part-way, so no key is ever left stuck down.
public enum KeySequence {
    public static let maximumSteps = 200
    public static let maximumTotalWaitMilliseconds = 10_000.0

    struct HeldKey: Equatable {
        let name: String
        let keyCode: CGKeyCode
        /// Set for modifier keys: held modifiers apply to every event sent while they are down.
        let modifierFlag: CGEventFlags?

        static func == (lhs: HeldKey, rhs: HeldKey) -> Bool {
            lhs.keyCode == rhs.keyCode
        }
    }

    enum Resolved: Equatable {
        case down(HeldKey)
        case up(HeldKey)
        case press(String)
        case wait(TimeInterval)

        static func == (lhs: Resolved, rhs: Resolved) -> Bool {
            switch (lhs, rhs) {
            case let (.down(a), .down(b)), let (.up(a), .up(b)):
                return a == b
            case let (.press(a), .press(b)):
                return a == b
            case let (.wait(a), .wait(b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// Reads the `steps` argument: an array of objects that each hold exactly one of
    /// `down`, `up`, `press` (strings) or `wait_ms` (number).
    public static func parse(_ raw: Any?) throws -> [KeySequenceStep] {
        guard let list = raw as? [Any] else {
            throw ComputerUseError.invalidArguments("steps must be an array of step objects")
        }

        return try list.enumerated().map { offset, item in
            guard let object = item as? [String: Any], object.count == 1, let (key, value) = object.first else {
                throw ComputerUseError.invalidArguments(
                    "step \(offset + 1) must be an object with exactly one of down, up, press or wait_ms"
                )
            }

            switch key {
            case "down", "up", "press":
                guard let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ComputerUseError.invalidArguments("step \(offset + 1): \(key) needs a key name")
                }
                return key == "down" ? .down(text) : key == "up" ? .up(text) : .press(text)
            case "wait_ms":
                let number: Double?
                if let value = value as? Double {
                    number = value
                } else if let value = value as? Int {
                    number = Double(value)
                } else {
                    number = nil
                }
                guard let number, number.isFinite, number >= 0 else {
                    throw ComputerUseError.invalidArguments("step \(offset + 1): wait_ms must be a number 0 or above")
                }
                return .wait(milliseconds: number)
            default:
                throw ComputerUseError.invalidArguments(
                    "step \(offset + 1): unknown action '\(key)'; use down, up, press or wait_ms"
                )
            }
        }
    }

    /// Checks the whole timeline before anything is sent: known keys, an `up` only for a held key,
    /// no double `down`, and the step and wait limits.
    static func resolve(_ steps: [KeySequenceStep]) throws -> [Resolved] {
        guard !steps.isEmpty else {
            throw ComputerUseError.invalidArguments("steps is empty")
        }
        guard steps.count <= maximumSteps else {
            throw ComputerUseError.invalidArguments("steps has \(steps.count) entries; the limit is \(maximumSteps)")
        }

        var held: [HeldKey] = []
        var totalWait = 0.0
        return try steps.enumerated().map { offset, step in
            let number = offset + 1
            switch step {
            case .down(let name):
                let key = try heldKey(name, step: number)
                guard !held.contains(key) else {
                    throw ComputerUseError.invalidArguments("step \(number): '\(name)' is already held")
                }
                held.append(key)
                return .down(key)
            case .up(let name):
                let key = try heldKey(name, step: number)
                guard let index = held.firstIndex(of: key) else {
                    throw ComputerUseError.invalidArguments("step \(number): '\(name)' is not held; add a down step for it first")
                }
                held.remove(at: index)
                return .up(key)
            case .press(let specification):
                _ = try KeyPressParser.parse(specification)
                return .press(specification)
            case .wait(let milliseconds):
                totalWait += milliseconds
                guard totalWait <= maximumTotalWaitMilliseconds else {
                    throw ComputerUseError.invalidArguments(
                        "the waits add up to more than \(Int(maximumTotalWaitMilliseconds)) ms"
                    )
                }
                return .wait(milliseconds / 1000)
            }
        }
    }

    static func heldKey(_ name: String, step: Int) throws -> HeldKey {
        let token = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch token {
        case "shift":
            return HeldKey(name: token, keyCode: CGKeyCode(kVK_Shift), modifierFlag: .maskShift)
        case "control", "ctrl":
            return HeldKey(name: token, keyCode: CGKeyCode(kVK_Control), modifierFlag: .maskControl)
        case "option", "alt":
            return HeldKey(name: token, keyCode: CGKeyCode(kVK_Option), modifierFlag: .maskAlternate)
        case "cmd", "command", "super", "meta":
            return HeldKey(name: token, keyCode: CGKeyCode(kVK_Command), modifierFlag: .maskCommand)
        default:
            guard !token.contains("+") else {
                throw ComputerUseError.invalidArguments(
                    "step \(step): down/up take one key; hold each key of a chord with its own down step"
                )
            }
            let parsed = try KeyPressParser.parse(token)
            return HeldKey(name: token, keyCode: parsed.keyCode, modifierFlag: nil)
        }
    }

    /// Sends the timeline to `pid`. Every key still held when it ends, or when a step fails, is released.
    static func run(_ steps: [Resolved], pid: pid_t) throws {
        try requireUsableComputerUseSession()
        var held: [HeldKey] = []
        var activeFlags: CGEventFlags = []

        func post(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) throws {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else {
                throw ComputerUseError.message("Failed to create key event.")
            }
            event.flags = flags
            event.postToPid(pid)
        }

        defer {
            for key in held.reversed() {
                if let flag = key.modifierFlag {
                    activeFlags.remove(flag)
                }
                try? post(key.keyCode, down: false, flags: activeFlags)
            }
        }

        for step in steps {
            switch step {
            case .down(let key):
                if let flag = key.modifierFlag {
                    activeFlags.insert(flag)
                }
                try post(key.keyCode, down: true, flags: activeFlags)
                held.append(key)
            case .up(let key):
                if let flag = key.modifierFlag {
                    activeFlags.remove(flag)
                }
                try post(key.keyCode, down: false, flags: activeFlags)
                held.removeAll { $0 == key }
            case .press(let specification):
                let parsed = try KeyPressParser.parse(specification)
                var flags = activeFlags
                for modifier in parsed.modifiers {
                    flags.insert(modifier.flag)
                    try post(modifier.keyCode, down: true, flags: flags)
                }
                try post(parsed.keyCode, down: true, flags: flags)
                try post(parsed.keyCode, down: false, flags: flags)
                for modifier in parsed.modifiers.reversed() {
                    try post(modifier.keyCode, down: false, flags: flags)
                    if !activeFlags.contains(modifier.flag) {
                        flags.remove(modifier.flag)
                    }
                }
            case .wait(let seconds):
                if seconds > 0 {
                    Thread.sleep(forTimeInterval: seconds)
                }
            }
        }
    }
}
