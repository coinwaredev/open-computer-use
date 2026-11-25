import AppKit
import XCTest
@testable import OpenComputerUseKit

final class FilePanelTests: XCTestCase {
    private let home = "/Users/me"
    private func names(_ path: String) -> String {
        ["/": "Macintosh HD", "/Users/me": "me"][path] ?? (path as NSString).lastPathComponent
    }
    private var anchors: [FilePanelPlan.Anchor] {
        FilePanelPlan.candidateAnchors(home: home, volumes: ["/Volumes/Art"], displayName: names)
    }

    func testPathsAreExpandedAndStandardized() throws {
        XCTAssertEqual(try FilePanelPlan.normalizedPath("~/art/a.fbx", home: home), "/Users/me/art/a.fbx")
        XCTAssertEqual(try FilePanelPlan.normalizedPath(" /Users/me/art/../b.fbx/ ", home: home), "/Users/me/b.fbx")
        for bad in ["art/a.fbx", "", "/", "~other/a.fbx"] {
            XCTAssertThrowsError(try FilePanelPlan.normalizedPath(bad, home: home), bad)
        }
    }

    func testTheDeepestShownSidebarPlaceStartsTheWalk() throws {
        let all = ["Macintosh HD", "me", "Documents", "Desktop", "Applications", "Art"]
        let plan = try FilePanelPlan.make(target: "/Users/me/Documents/art/a.fbx", anchors: anchors, sidebarNames: all)
        XCTAssertEqual(plan.anchor, .init(name: "Documents", path: "/Users/me/Documents"))
        XCTAssertEqual(plan.steps, ["/Users/me/Documents/art", "/Users/me/Documents/art/a.fbx"])

        let homeOnly = try FilePanelPlan.make(target: "/Users/me/Documents/a.fbx", anchors: anchors, sidebarNames: ["me"])
        XCTAssertEqual(homeOnly.anchor.path, "/Users/me")
        XCTAssertEqual(homeOnly.steps, ["/Users/me/Documents", "/Users/me/Documents/a.fbx"])

        let disk = try FilePanelPlan.make(target: "/opt/x/a.fbx", anchors: anchors, sidebarNames: all)
        XCTAssertEqual(disk.anchor.path, "/")
        XCTAssertEqual(disk.steps, ["/opt", "/opt/x", "/opt/x/a.fbx"])

        let volume = try FilePanelPlan.make(target: "/Volumes/Art/a.fbx", anchors: anchors, sidebarNames: all)
        XCTAssertEqual(volume.anchor.name, "Art")
        XCTAssertEqual(volume.steps, ["/Volumes/Art/a.fbx"])
    }

    func testNoSidebarPlaceAboveThePathIsAClearError() {
        XCTAssertThrowsError(try FilePanelPlan.make(target: "/opt/a.fbx", anchors: anchors, sidebarNames: ["me", "Documents"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Sidebar"), error.localizedDescription)
        }
        XCTAssertFalse(FilePanelPlan.isAncestor("/Users/me/Doc", of: "/Users/me/Documents/a"), "a prefix of a name is not a parent")
    }

    func testRowsAndWhereMatchFinderNames() {
        XCTAssertTrue(FilePanelPlan.rowNames("a.fbx", path: "/x/a.fbx", displayName: "a"))
        XCTAssertTrue(FilePanelPlan.rowNames("a", path: "/x/a.fbx", displayName: "a"), "extension hidden by Finder")
        XCTAssertFalse(FilePanelPlan.rowNames("a.fbx.bak", path: "/x/a.fbx", displayName: "a"))
        XCTAssertTrue(FilePanelPlan.whereShows("TextEdit — iCloud", folderName: "TextEdit"))
        XCTAssertTrue(FilePanelPlan.whereShows("art", folderName: "art"))
        XCTAssertFalse(FilePanelPlan.whereShows("artwork", folderName: "art"))
        XCTAssertFalse(FilePanelPlan.whereShows(nil, folderName: "art"))
    }

    func testToolSchema() throws {
        let tool = try XCTUnwrap(ToolDefinitions.all.first { $0.name == "choose_file" })
        let schema = tool.inputSchema
        XCTAssertEqual(schema["required"] as? [String], ["app", "path"])
    }

    /// Drives a real Open panel: set OCU_LIVE_FILE_PANEL_BUNDLE (an app showing an Open panel) and
    /// OCU_LIVE_FILE_PANEL_PATH (a visible file it accepts).
    func testLiveOpenPanel() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bundle = env["OCU_LIVE_FILE_PANEL_BUNDLE"], let path = env["OCU_LIVE_FILE_PANEL_PATH"] else {
            throw XCTSkip("set OCU_LIVE_FILE_PANEL_BUNDLE and OCU_LIVE_FILE_PANEL_PATH to drive a real panel")
        }
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first)
        let start = Date()
        var driver = FilePanelDriver(pid: app.processIdentifier, hintWindows: [], checkSession: {})
        driver.trace = { print(String(format: "  %.2f s  ", Date().timeIntervalSince(start)) + $0) }
        let outcome = try driver.choose(path: path)
        print("choose_file live: \(outcome.path) from \(outcome.anchor), list view switch \(outcome.switchedToListView), \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    }
}
