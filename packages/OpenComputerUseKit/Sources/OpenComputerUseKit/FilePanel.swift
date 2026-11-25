import ApplicationServices
import Foundation

/// choose_file: pick a file in an app's macOS Open panel by path.
///
/// The panel's contents are a remote view served by the separate Open and Save Panel Service, so synthetic keys
/// (Go to Folder) and pointer clicks sent to the app never reach them. Accessibility does: sidebar and file-name
/// cells answer `AXOpen`, rows take a settable `AXSelected`, and the Open button is `OKButton`. The walk opens a
/// sidebar place above the path, opens each folder below it, then selects the file and presses Open.
struct FilePanelPlan: Equatable {
    struct Anchor: Equatable {
        /// The name the sidebar shows (Finder's display name).
        let name: String
        let path: String
    }

    let anchor: Anchor
    /// Full paths to open below the anchor, in order; the last is the file.
    let steps: [String]

    /// Expands `~`, requires an absolute path and standardizes it (`..`, `//`, a trailing slash).
    static func normalizedPath(_ raw: String, home: String) throws -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst(1)
        }
        guard path.hasPrefix("/") else {
            throw ComputerUseError.invalidArguments("path must be absolute or start with ~/")
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized != "/" else {
            throw ComputerUseError.invalidArguments("path must name a file, not /")
        }
        return standardized
    }

    /// The sidebar places a walk can start from: the startup disk, Applications, Home and its usual folders,
    /// and mounted volumes. Which ones the panel shows depends on the user's Finder sidebar settings.
    static func candidateAnchors(home: String, volumes: [String], displayName: (String) -> String) -> [Anchor] {
        let paths = ["/", "/Applications", home]
            + ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home + "/" + $0 }
            + volumes
        return paths.map { Anchor(name: displayName($0), path: $0) }
    }

    static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        ancestor == "/" ? path != "/" : path.hasPrefix(ancestor + "/")
    }

    /// The deepest anchor that the sidebar shows and that holds the target, then each path below it.
    static func make(target: String, anchors: [Anchor], sidebarNames: [String]) throws -> FilePanelPlan {
        let shown = Set(sidebarNames)
        guard let anchor = anchors
            .filter({ shown.contains($0.name) && isAncestor($0.path, of: target) })
            .max(by: { $0.path.count < $1.path.count })
        else {
            throw ComputerUseError.stateUnavailable(
                "the panel's sidebar shows no place above \(target) (it shows: \(sidebarNames.prefix(12).joined(separator: ", "))). "
                    + "Turn on the startup disk or Home in Finder > Settings > Sidebar, or open a folder above the file in the panel first"
            )
        }
        let anchorDepth = URL(fileURLWithPath: anchor.path).pathComponents.count
        let components = URL(fileURLWithPath: target).pathComponents
        var steps: [String] = []
        var current = anchor.path
        for name in components.dropFirst(anchorDepth) {
            current = current == "/" ? "/" + name : current + "/" + name
            steps.append(current)
        }
        return FilePanelPlan(anchor: anchor, steps: steps)
    }

    /// A row names a path when it shows the file name or Finder's display name (localized, extension hidden).
    static func rowNames(_ row: String, path: String, displayName: String) -> Bool {
        row == (path as NSString).lastPathComponent || row == displayName
    }

    /// The Where pop-up shows the current folder, sometimes with a suffix such as "TextEdit — iCloud".
    static func whereShows(_ value: String?, folderName: String) -> Bool {
        guard let value else { return false }
        return value == folderName || value.hasPrefix(folderName + " ")
    }
}

/// Drives one Open panel through accessibility. Every wait polls with a deadline; nothing here sends keys or
/// pointer events.
struct FilePanelDriver {
    let pid: pid_t
    /// Extra windows to look in first, such as the snapshot's key window.
    let hintWindows: [AXUIElement]
    let checkSession: () throws -> Void
    var displayName: (String) -> String = { FileManager.default.displayName(atPath: $0) }
    var folderTimeout: TimeInterval = 8
    var pollInterval: TimeInterval = 0.1
    /// Step timings for diagnosis (the live test prints them).
    var trace: ((String) -> Void)?

    struct Outcome {
        let path: String
        let anchor: String
        let switchedToListView: Bool
    }

    func choose(path rawPath: String) throws -> Outcome {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let target = try FilePanelPlan.normalizedPath(rawPath, home: home)
        try requireReachableFile(target)

        guard let panel = findPanel() else {
            throw ComputerUseError.stateUnavailable(
                "no Open panel found in this app; open the app's file dialog first (for example File > Open), then call choose_file"
            )
        }
        if isSavePanel(panel) {
            throw ComputerUseError.message("this is a Save panel; choose_file only picks files in Open panels")
        }

        let switched = try ensureListView(in: panel)
        let sidebar = sidebarCells(in: panel)
        let volumes = ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            .map { "/Volumes/" + $0 }
            .filter { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) == nil }
        let plan = try FilePanelPlan.make(
            target: target,
            anchors: FilePanelPlan.candidateAnchors(home: home, volumes: volumes, displayName: displayName),
            sidebarNames: sidebar.map(\.name)
        )

        try checkSession()
        guard let anchorCell = sidebar.first(where: { $0.name == plan.anchor.name })?.cell else {
            throw ComputerUseError.stateUnavailable("could not find \(plan.anchor.name) in the panel's sidebar")
        }
        trace?("found panel, sidebar and plan")
        open(anchorCell)
        try waitForFolder(plan.anchor.name, in: panel)
        trace?("opened \(plan.anchor.name)")

        for (offset, step) in plan.steps.enumerated() {
            let isFile = offset == plan.steps.count - 1
            let name = displayName(step)
            let row = try waitForRow(path: step, displayName: name, in: panel)
            trace?("found row \(name)")
            try checkSession()
            if isFile {
                try pickFile(row: row, name: name, in: panel)
            } else {
                guard let cell = nameCell(of: row) else {
                    throw ComputerUseError.stateUnavailable("could not open the folder \(name) in the panel")
                }
                open(cell)
                try waitForFolder(name, in: panel)
                trace?("opened \(name)")
            }
        }
        return Outcome(path: target, anchor: plan.anchor.name, switchedToListView: switched)
    }

    // MARK: - Steps

    /// The panel service answers AXOpen with kAXErrorActionUnsupported even when it opens the place, so the
    /// result code says nothing; the caller confirms the move from the Where pop-up instead.
    private func open(_ cell: AXUIElement) {
        _ = AXUIElementPerformAction(cell, "AXOpen" as CFString)
    }

    private func requireReachableFile(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ComputerUseError.invalidArguments("no file at \(path)")
        }
        guard !isDirectory.boolValue || NSWorkspaceFilePackage.isPackage(path) else {
            throw ComputerUseError.invalidArguments("\(path) is a folder; choose_file picks a file")
        }
        // Panels hide dot-files and hidden folders (such as /private or /tmp), so a walk could never see them.
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true {
                throw ComputerUseError.invalidArguments(
                    "\(url.path) is hidden, and Open panels don't list hidden items; copy the file somewhere visible first"
                )
            }
            url.deleteLastPathComponent()
        }
    }

    private func pickFile(row: AXUIElement, name: String, in panel: AXUIElement) throws {
        guard AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw ComputerUseError.stateUnavailable("could not select \(name) in the panel")
        }
        guard let ok = control("OKButton", in: panel) else {
            throw ComputerUseError.stateUnavailable("the panel has no Open button")
        }
        guard poll(timeout: 1.5, { boolValue(ok, kAXEnabledAttribute) == true }) else {
            throw ComputerUseError.message(
                "the panel won't accept \(name) (its Open button stays disabled; the app probably doesn't take this file type)"
            )
        }
        try checkSession()
        guard AXUIElementPerformAction(ok, kAXPressAction as CFString) == .success else {
            throw ComputerUseError.stateUnavailable("pressing the panel's Open button failed")
        }
        // Once the panel closes its button is gone, and reading it fails.
        guard poll(timeout: 3, { boolValue(ok, kAXEnabledAttribute) == nil }) else {
            throw ComputerUseError.stateUnavailable("pressed Open, but the panel is still showing; check it with get_app_state")
        }
    }

    private func waitForFolder(_ name: String, in panel: AXUIElement) throws {
        let popup = control("where popup", in: panel)
        guard let popup, poll(timeout: folderTimeout, {
            FilePanelPlan.whereShows(stringValue(popup, kAXValueAttribute), folderName: name)
        }) else {
            throw ComputerUseError.stateUnavailable(
                "the panel did not open \(name). If the app is on another Space or behind a full-screen app, the panel can't load; switch to its desktop and try again"
            )
        }
    }

    private func waitForRow(path: String, displayName: String, in panel: AXUIElement) throws -> AXUIElement {
        var seen: [String] = []
        var found: AXUIElement?
        _ = poll(timeout: folderTimeout) {
            seen = []
            for row in listRows(in: panel) {
                guard let cell = children(row).first, let text = cellText(cell) else { continue }
                seen.append(text)
                if FilePanelPlan.rowNames(text, path: path, displayName: displayName) {
                    found = row
                    return true
                }
            }
            return false
        }
        guard let found else {
            let shown = seen.isEmpty ? "nothing (the list did not load)" : seen.prefix(15).joined(separator: ", ")
            throw ComputerUseError.stateUnavailable("the panel lists no \(displayName); it shows \(shown)")
        }
        return found
    }

    /// Icon and column views expose files differently; list view is the one this walk reads, so switch to it with
    /// the View Options menu (its items carry the same identifiers in every language).
    private func ensureListView(in panel: AXUIElement) throws -> Bool {
        if listView(in: panel) != nil {
            return false
        }
        guard let viewButton = control("View Options", in: panel),
              AXUIElementPerformAction(viewButton, kAXPressAction as CFString) == .success
        else {
            throw ComputerUseError.stateUnavailable("the panel is not in list view, and its View Options menu could not be opened")
        }
        var item: AXUIElement?
        _ = poll(timeout: 1.5) {
            item = descendant(of: viewButton, maxDepth: 4, where: { identifier($0) == "cmdViewAsList:" })
                ?? descendant(of: panel, maxDepth: 10, where: { identifier($0) == "cmdViewAsList:" })
            return item != nil
        }
        guard let item, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            if let menu = descendant(of: viewButton, maxDepth: 3, where: { role($0) == kAXMenuRole as String }) {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
            throw ComputerUseError.stateUnavailable("could not switch the panel to list view")
        }
        guard poll(timeout: 2, { listView(in: panel) != nil }) else {
            throw ComputerUseError.stateUnavailable("the panel did not switch to list view")
        }
        return true
    }

    // MARK: - Finding things

    func findPanel() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windows = hintWindows
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = element(app, attribute) {
                windows.append(window)
            }
        }
        windows += (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []

        var seen: [AXUIElement] = []
        for window in windows where !seen.contains(where: { CFEqual($0, window) }) {
            seen.append(window)
            // A panel shown as a sheet hangs off its document window.
            let sheets = children(window).filter { role($0) == kAXSheetRole as String }
            for candidate in sheets + [window] where isOpenOrSavePanel(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isOpenOrSavePanel(_ element: AXUIElement) -> Bool {
        // Open and Save panels both carry these; isSavePanel tells them apart.
        let found = controls(in: element, ids: ["OKButton", "where popup"])
        return found.count == 2
    }

    private func isSavePanel(_ panel: AXUIElement) -> Bool {
        if let id = identifier(panel), id.localizedCaseInsensitiveContains("save") {
            return true
        }
        return control("saveAsNameTextField", in: panel) != nil
    }

    private func listView(in panel: AXUIElement) -> AXUIElement? {
        control("ListView", in: panel)
    }

    private func control(_ id: String, in panel: AXUIElement) -> AXUIElement? {
        controls(in: panel, ids: [id])[id]
    }

    /// Finds the panel's own controls by identifier, breadth first. It never walks into the file list, the
    /// sidebar or other item containers: every AX read is a round trip to the panel service, and a folder's rows
    /// can number in the hundreds.
    private func controls(in panel: AXUIElement, ids: Set<String>) -> [String: AXUIElement] {
        let containers: Set<String> = [
            kAXOutlineRole, kAXBrowserRole, kAXListRole, kAXTableRole, kAXRowRole, kAXScrollBarRole, kAXCellRole, "AXCollection",
        ].reduce(into: []) { $0.insert($1 as String) }
        var found: [String: AXUIElement] = [:]
        var level = [panel]
        var depth = 0
        while !level.isEmpty, depth <= 8, found.count < ids.count {
            var next: [AXUIElement] = []
            for element in level {
                let (elementRole, elementID) = roleAndIdentifier(element)
                if let elementID, ids.contains(elementID), found[elementID] == nil {
                    found[elementID] = element
                }
                if let elementRole, containers.contains(elementRole) {
                    continue
                }
                next += children(element)
            }
            level = next
            depth += 1
        }
        return found
    }

    /// Role and identifier in one round trip.
    private func roleAndIdentifier(_ element: AXUIElement) -> (String?, String?) {
        var values: CFArray?
        let names = [kAXRoleAttribute, kAXIdentifierAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(), &values) == .success,
              let list = values as? [AnyObject], list.count == 2
        else {
            return (nil, nil)
        }
        return (list[0] as? String, list[1] as? String)
    }

    private func listRows(in panel: AXUIElement) -> [AXUIElement] {
        guard let list = listView(in: panel) else {
            return []
        }
        return (value(list, kAXRowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Sidebar outlines: every outline in the panel except the file list, keeping cells that answer AXOpen.
    private func sidebarCells(in panel: AXUIElement) -> [(name: String, cell: AXUIElement)] {
        var outlines: [AXUIElement] = []
        collect(from: panel, maxDepth: 6, into: &outlines) { role($0) == kAXOutlineRole as String && identifier($0) != "ListView" }
        var cells: [(String, AXUIElement)] = []
        for outline in outlines {
            for row in (value(outline, kAXRowsAttribute) as? [AXUIElement]) ?? children(outline) {
                if let cell = nameCell(of: row), let name = cellText(cell) {
                    cells.append((name, cell))
                }
            }
        }
        return cells
    }

    /// The first cell of a row that answers AXOpen: the name column in list view, the place in the sidebar.
    private func nameCell(of row: AXUIElement) -> AXUIElement? {
        children(row).first { actions($0).contains("AXOpen") }
    }

    /// The name a cell shows: its first child whose value is text (the icon beside it has none).
    private func cellText(_ cell: AXUIElement) -> String? {
        for child in children(cell) {
            if let text = stringValue(child, kAXValueAttribute), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    // MARK: - AX helpers

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            return nil
        }
        return result as AnyObject?
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    private func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    private func role(_ element: AXUIElement) -> String? {
        stringValue(element, kAXRoleAttribute)
    }

    private func identifier(_ element: AXUIElement) -> String? {
        stringValue(element, kAXIdentifierAttribute)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return []
        }
        return (names as? [String]) ?? []
    }

    private func descendant(of root: AXUIElement, maxDepth: Int, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(root) {
            return root
        }
        guard maxDepth > 0 else {
            return nil
        }
        for child in children(root) {
            if let found = descendant(of: child, maxDepth: maxDepth - 1, where: match) {
                return found
            }
        }
        return nil
    }

    private func collect(from root: AXUIElement, maxDepth: Int, into found: inout [AXUIElement], where match: (AXUIElement) -> Bool) {
        if match(root) {
            found.append(root)
            return
        }
        guard maxDepth > 0 else {
            return
        }
        for child in children(root) {
            collect(from: child, maxDepth: maxDepth - 1, into: &found, where: match)
        }
    }
}

/// A bundle such as an `.app` or `.rtfd` is a folder on disk but a file in a panel.
enum NSWorkspaceFilePackage {
    static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }
}
