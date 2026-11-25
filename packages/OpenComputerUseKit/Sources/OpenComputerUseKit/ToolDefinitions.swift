import Foundation

public struct ToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let annotations: [String: Any]
    public let inputSchema: [String: Any]

    public init(name: String, description: String, annotations: [String: Any], inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.annotations = annotations
        self.inputSchema = inputSchema
    }

    public var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]

        if !annotations.isEmpty {
            dictionary["annotations"] = annotations
        }

        return dictionary
    }
}

public enum ToolDefinitions {
    public static var all: [ToolDefinition] {
        configured(virtualDisplayEnabled: VirtualDisplayConfig.current.enabled)
    }

    static func configured(virtualDisplayEnabled: Bool) -> [ToolDefinition] {
        guard !virtualDisplayEnabled else { return definitions }
        return definitions.map { tool in
            guard tool.name == "get_app_state" else { return tool }
            var schema = tool.inputSchema
            var properties = schema["properties"] as? [String: Any] ?? [:]
            properties.removeValue(forKey: "window_placement")
            schema["properties"] = properties
            return ToolDefinition(name: tool.name, description: tool.description, annotations: tool.annotations, inputSchema: schema)
        }
    }

    private static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "click",
            description: "Click an element by index or pixel coordinates from screenshot. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element index to click"),
                    "x": numberProperty(description: "X coordinate in screenshot pixel coordinates"),
                    "y": numberProperty(description: "Y coordinate in screenshot pixel coordinates"),
                    "click_count": integerProperty(description: "Number of clicks. Defaults to 1"),
                    "mouse_button": stringProperty(
                        description: "Mouse button to click. Defaults to left.",
                        enumValues: ["left", "right", "middle"]
                    ),
                    "click_method": stringProperty(
                        description: "Click implementation: auto (default), accessibility, app_post, sky_click, or global. Accessibility requires element_index. app_post sends a public event directly to the target app. sky_click uses the macOS SkyLight background window path. Global may move the system pointer and requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1.",
                        enumValues: ClickMethod.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "drag",
            description: "Drag from one point to another using pixel coordinates, with any mouse button. By default the drag goes to the target window through SkyLight: a background window takes it without coming to the front and the system pointer does not move. That covers sliders, canvases, and a right drag that turns a game camera. Window-server drag sessions such as window moves or Finder drag-and-drop need drag_method global, which requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 in the server process environment and may move the real pointer. The result reports which path was used. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "from_x": numberProperty(description: "Start X coordinate"),
                    "from_y": numberProperty(description: "Start Y coordinate"),
                    "to_x": numberProperty(description: "End X coordinate"),
                    "to_y": numberProperty(description: "End Y coordinate"),
                    "mouse_button": stringProperty(
                        description: "Mouse button held during the drag. Defaults to left; right turns the camera in many 3D views.",
                        enumValues: ["left", "right", "middle"]
                    ),
                    "duration_ms": numberProperty(description: "How long the move from start to end takes, 0-10000 ms. Defaults to 250. Longer turns a game camera more smoothly; the global and app_post paths ignore it."),
                    "drag_method": stringProperty(
                        description: "Delivery: auto (default: sky, then app_post; global when OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1), sky, app_post, or global.",
                        enumValues: DragMethod.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app", "from_x", "from_y", "to_x", "to_y"]
            )
        ),
        ToolDefinition(
            name: "hover",
            description: "Move the pointer over an element or a screenshot point without clicking, so hover styles, hover menus and tooltips show. Goes to the target window through SkyLight: the window does not come to the front and the system pointer does not move. Returns the app state after a short pause; system tooltips take about a second, so read the app again for those. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element to hover over"),
                    "x": numberProperty(description: "X coordinate in screenshot pixel coordinates"),
                    "y": numberProperty(description: "Y coordinate in screenshot pixel coordinates"),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "query",
            description: "Targeted accessibility lookup: find controls in the app's current window using bounded AX traversal, with no full snapshot and no screenshot. Returns matches with truncated, stop_reason, visited_nodes and window_id metadata. Each match has a session-local `index` usable by the element actions (click, set_value, scroll, perform_secondary_action). Requires text and/or role. Only queries already-running apps; indexes expire after 120 seconds. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Match text in the control's title, description or value (up to 1000 UTF-16 code units). Case-insensitive substring unless exact is true. Long fields are bounded and reported as truncated."),
                    "role": stringProperty(description: "Match this accessibility role (the AX prefix is optional, e.g. button or AXButton)"),
                    "exact": [
                        "type": "boolean",
                        "description": "Require a complete text match instead of a substring. Defaults to false. No substring retry.",
                    ],
                    "limit": positiveIntegerProperty(description: "Maximum matches to return. Defaults to 20; capped at 100."),
                    "max_nodes": positiveIntegerProperty(description: "Node/queue cap for AX traversal. Defaults to 500; capped at 5000. Search has a 2-second cooperative deadline."),
                    "window_id": positiveIntegerProperty(description: "Search this specific window (CGWindowID, 1–4294967295) instead of the app's current window."),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "get_app_state",
            description: "Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "include_ax": ["type": "boolean", "default": true, "description": "Include accessibility tree, focus and selection. False skips collection and invalidates previous element indexes; read AX again before element actions."],
                    "include_screenshot": ["type": "boolean", "default": true, "description": "Capture and return a screenshot. False skips capture and encoding; screenshot-coordinate actions require a fresh screenshot."],
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text_limit": textLimitProperty(description: "Maximum text characters to return. Use \"max\" for full text. Defaults to 500."),
                    "max_tree_nodes": positiveIntegerProperty(description: "Maximum accessibility tree nodes to render. Defaults to 1200."),
                    "max_tree_depth": positiveIntegerProperty(description: "Maximum accessibility tree depth to render. Defaults to 64."),
                    "window_placement": stringProperty(
                        description: "keep (default) leaves the window where it is. agent_display (macOS) parks the app's window on an invisible display owned by the agent so a covered or other-Space window renders, exposes its full tree and accepts input without touching the user's Space, focus or pointer; the window disappears from the user's desktop until restore or process exit. restore puts it back.",
                        enumValues: WindowPlacement.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "list_apps",
            description: "List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Invoke a secondary accessibility action exposed by an element. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "action": stringProperty(description: "Secondary accessibility action name"),
                ],
                required: ["app", "element_index", "action"]
            )
        ),
        ToolDefinition(
            name: "press_key",
            description: "Press a key or key-combination on the keyboard, including modifier and navigation keys.\n  - This supports xdotool's `key` syntax.\n  - Examples: \"a\", \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\" (for the numpad 0 key). This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "key": stringProperty(description: "Key or key combination to press"),
                    "key_method": keyMethodProperty(),
                    "hold_ms": numberProperty(description: "Optional: hold the key down this many milliseconds (0-10000) before releasing, for games that read held keys. Default 0 (tap)."),
                ],
                required: ["app", "key"]
            )
        ),
        ToolDefinition(
            name: "key_sequence",
            description: "Hold, release and tap keys on one timeline so keys can overlap, for example hold W, tap Space, keep walking. Steps run in order in one call; each step is an object with exactly one of `down` (hold one key or modifier), `up` (release a held key), `press` (tap a key or chord, press_key syntax) or `wait_ms` (pause while held keys stay down). Keys still held at the end are released. Limits: \(KeySequence.maximumSteps) steps, \(Int(KeySequence.maximumTotalWaitMilliseconds)) ms of waits. Games usually need key_method `sky_key`. Example steps: [{\"down\":\"w\"},{\"wait_ms\":300},{\"press\":\"space\"},{\"wait_ms\":700},{\"up\":\"w\"}]. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "steps": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": KeySequence.maximumSteps,
                        "description": "Timeline steps, each an object with exactly one of down, up, press (strings) or wait_ms (number).",
                        "items": [
                            "type": "object",
                            "minProperties": 1,
                            "maxProperties": 1,
                            "properties": [
                                "down": ["type": "string"],
                                "up": ["type": "string"],
                                "press": ["type": "string"],
                                "wait_ms": ["type": "number", "minimum": 0],
                            ],
                            "additionalProperties": false,
                        ] as [String: Any],
                    ] as [String: Any],
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "steps"]
            )
        ),
        ToolDefinition(
            name: "choose_file",
            description: "Pick a file in the app's open macOS Open panel by its path, then press Open. Works in the background through accessibility: the panel's file list is drawn by a separate macOS service, so keys (Go to Folder) and clicks never reach it. Open the panel first (for example File > Open or an Import menu item). The walk starts from a place in the panel's sidebar (the disk, Home, Documents, a volume) and opens each folder down to the file; a panel in icon or column view is switched to list view. Hidden files and Save panels are refused. If the app is on another Space or behind a full-screen app, the panel can't load its files. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "path": stringProperty(description: "Absolute path of the file to pick, or one starting with ~/"),
                ],
                required: ["app", "path"]
            )
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll an element in a direction by a number of pages. Without element_index, scroll at a screenshot point (x/y) or, with neither, at the window's centre: wheel events go to the window through SkyLight without bringing it to the front, for views with no accessibility tree such as game views (the wheel zooms the camera) and canvases. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "direction": stringProperty(description: "Scroll direction: up, down, left, or right"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "x": numberProperty(description: "X coordinate in screenshot pixel coordinates, when there is no element_index"),
                    "y": numberProperty(description: "Y coordinate in screenshot pixel coordinates, when there is no element_index"),
                    "pages": numberProperty(description: "Number of pages to scroll. Fractional values are supported. Defaults to 1"),
                ],
                required: ["app", "direction"]
            )
        ),
        ToolDefinition(
            name: "set_value",
            description: "Set the value of a settable accessibility element and verify the actual value. Text is compared exactly, including whitespace; an empty string clears it. Unverified writes return an error, even when full action read-back is disabled. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "value": stringProperty(description: "Value to assign"),
                ],
                required: ["app", "element_index", "value"]
            )
        ),
        ToolDefinition(
            name: "select_text",
            description: "Select text inside a text element, or place the text cursor before or after it. Provide text exactly as it appears in the accessibility tree, including any Markdown formatting. If the text is not unique, provide surrounding prefix or suffix text to disambiguate it. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Text element identifier"),
                    "text": stringProperty(description: "Target text as shown in the accessibility tree"),
                    "prefix": stringProperty(description: "Optional text immediately before the target, used to disambiguate repeated matches"),
                    "suffix": stringProperty(description: "Optional text immediately after the target, used to disambiguate repeated matches"),
                    "selection": stringProperty(
                        description: "Whether to select the text or place the cursor before or after it. Defaults to text.",
                        enumValues: TextSelectionMode.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app", "element_index", "text"]
            )
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type literal text using keyboard input. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Literal text to type"),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "text"]
            )
        ),
    ]
}

private func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]

    if !required.isEmpty {
        schema["required"] = required
    }

    return schema
}

private func defaultAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "openWorldHint": false,
    ]
}

private func readOnlyAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
        "readOnlyHint": true,
    ]
}

private func keyMethodProperty() -> [String: Any] {
    stringProperty(
        description: "Keyboard delivery: auto (default) or sky_key. sky_key posts authenticated keyboard events through the macOS SkyLight background-window path to the current target window without changing foreground focus. Requires a current on-screen target window from get_app_state.",
        enumValues: KeyMethod.allCases.map(\.rawValue)
    )
}

private func stringProperty(description: String, enumValues: [String]? = nil) -> [String: Any] {
    var property: [String: Any] = [
        "type": "string",
        "description": description,
    ]

    if let enumValues {
        property["enum"] = enumValues
    }

    return property
}

private func integerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "description": description,
    ]
}

private func positiveIntegerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "minimum": 1,
        "description": description,
    ]
}

private func textLimitProperty(description: String) -> [String: Any] {
    [
        "anyOf": [
            [
                "type": "integer",
                "minimum": 1,
            ],
            [
                "type": "string",
                "enum": [SnapshotTextLimit.maxKeyword],
            ],
        ],
        "description": description,
    ]
}

private func numberProperty(description: String) -> [String: Any] {
    [
        "type": "number",
        "description": description,
    ]
}
