# macOS：每个会话一个软件光标

用户同时开着几个聊天，它们都在用 OCU。软件光标是 App Agent 里的一个全局对象，所以：
- 两个会话交替操作时，同一个光标在两个目标之间来回飞。
- 任何一个会话结束（或收到 `notifications/turn-ended`）都会把所有会话的光标一起重置。
- 窗口跟随用的 frame 跟踪器也只记一个窗口，会话之间会互相挤掉。

改动：
- 新增 `VisualCursorChannel`，每个 `ComputerUseService` 一个，App Agent 的每个客户端连接（每个聊天）因此各有一个。它自带：
  - 队列代号（重置只取消本会话排队的动画）；
  - `CursorWindowFrames`（原 `CursorWindowFrameTracker` 改为实例，静态入口转发到共享默认实例）；
  - 屏幕上的 `VisualCursor`（原 `SoftwareCursorOverlay` 的静态状态改为实例）。
- 会话光标第一次绘制时按顺序取颜色：蓝、橙、绿、粉、紫、青，循环使用。颜色用 `.sourceAtop` 盖在原图上，保留明暗；默认光标（一次性 CLI、测试）保持原色。
- `StdioMCPServer.endSession()` 只重置本会话的光标；进程级的 turn-ended 分布式通知不带会话信息，仍重置所有光标。
- 会话结束、服务释放后，光标窗口在主线程上撤下，计时器停止。
- `VisualCursorSupport`、`SoftwareCursorOverlay`、`CursorWindowFrameTracker` 的静态 API 保留，作用于共享默认光标，现有调用和测试不变。
- 实测两个 MCP 会话同时点击时，B 的光标要等 A 的滑动结束才出现：动画在主队列的块内抽 run loop，主队列是串行的。现在工具调用（非主线程）的光标工作进入各光标自己的队列，动画按帧由该光标的 1/120 s 计时器推进，不再占住主队列；主线程调用仍内联播放，原有测试不变。

验证：
- `SessionCursorTests`：
  - 重置会话 A 只取消 A 排队的工作，B 的照常执行；
  - turn-ended 重置所有会话；
  - 各会话的窗口跟踪互不影响；
  - 每个服务有自己的光标；
  - 颜色循环且相邻会话不同；
  - 两个会话的光标同时显示在各自的位置，A 结束后 B 的光标仍在原处。
  - 两个会话从非主线程排队的滑动在同一帧里一起移动（旧的主队列方式下此测试失败：只有 1 帧重叠）。
- 实机：已安装的应用上 `choose_file` 1.4 s 打开 TextEdit 的文件；两个 `ocu mcp` 会话交替点击 TextEdit 和 Preview，光标窗口逐帧记录，没有一帧跑到左下角。
- `swift test` 全部通过。

由 Claude Code（claude-opus-5-5）实现，用户验证。
