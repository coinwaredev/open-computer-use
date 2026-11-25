# macOS：更快的点击和像手一样的光标

用户要求点击"尽可能快、像原生点击一样"。

## 实测拆解（TextEdit，带 read-back 的一次点击，进程内 `OPEN_COMPUTER_USE_DEBUG_TIMING=1`）

- 中位数 404 ms：
  - 动作后固定 sleep 155 ms（`pauseBeforeReadBack(0.15)`）；
  - read-back 快照 242 ms，其中菜单栏遍历 153 ms，窗口截图 32 ms，树遍历 29 ms，缩放和 PNG 编码 17 ms。
- App Agent 里 read-back 还会重新解析应用：列出并排序所有运行中的应用，排序比较函数里每次都读 `isActive`（LaunchServices 往返）。

## 改动

- 菜单栏项总是不输出子节点（`shouldSuppressChildren`），但规划阶段仍遍历每个关闭的菜单。现在规划在菜单栏项处停下，输出不变（实测 get_app_state 文本前后一致）。
- `pauseBeforeReadBack` 上限 40 ms（`OPEN_COMPUTER_USE_READ_BACK_SETTLE_MS`），因为 AX 动作返回时应用已处理完动作，只需等重绘。choose_file 保留 0.3 s。
- read-back 复用本会话已解析且仍在运行的应用；`runningApps()` 每个应用只读一次属性再排序；名称解析只对匹配的应用读取 activation policy。
- 光标滑动时长按距离对数增长（Fitts）：0.12 s 起，窗口内约 0.2 s，最多 0.4 s。原来固定为官方弹簧时间（约 1.4 s），聊天在两次操作之间思考超过 2 s，突发加速从不生效。`OPEN_COMPUTER_USE_CURSOR_MOTION=classic` 恢复原时长。点击脉冲 0.16 s 改为 0.1 s。
- 单元测试会把默认光标移到屏幕原点（左下角），用户把测试运行看成光标故障。XCTest 进程里光标视图隐藏，`OCU_TEST_SHOW_CURSOR=1` 可显示。

## 结果

- 进程内：TextEdit 点击中位数 404 ms 降到 110 ms。
- 已安装应用经 MCP：351 ms 降到 142 ms。
- 光标滑动 250-300 px 用时 180-200 ms（原来约 1.4 s），没有左下角帧。
- `swift test` 485 个测试全部通过。

## 后续：没有 AX press 的元素

- 滚动条等没有 AX 动作的元素走事件回退：命中测试约 10 ms，然后按 pid 投递鼠标事件，三次固定 30 ms 间隔。
- 实测（TextEdit 后台窗口，每种 20 次以内）：pid 投递的点击 0/10 落地（间隔 30、10、0 ms 都一样），后台 Cocoa 窗口直接丢弃；`sky_click` 10/10 落地，不抬起窗口。回退原来报告成功但没有点击。
- 回退现在先试 `sky_click`（左键，1-2 次，有窗口 id 和边界时），失败才走原来的全局或 pid 投递。pid 投递间隔可用 `OPEN_COMPUTER_USE_MOUSE_EVENT_GAP_MS` 调（默认 30）。
- `sky_click` 结束焦点记录后的 10 ms 等待去掉：之后没有事件，WindowServer 按顺序处理下一次激活记录。为 Chromium 调的间隔（primer、渲染器等待）不动。
- 结果：TextEdit 后台 `sky_click` 20/20 落地，`service.click` 163 ms 降到 136 ms；Preview 滚动条经 MCP 中位数 191 ms（含 read-back 截图）。`swift test` 486 个测试通过。

## 后续：Chrome 里 type_text 不落字

- 用户在 Chrome 里实测：默认 `type_text` 报告成功，但 Google 搜索框和 Amazon 搜索框都是空的；`press_key` Return 能到达。
- 原因：Chrome 网页输入框的 AXSelectedText 可写，`AXUIElementSetAttributeValue` 返回成功，但什么都不插入。旧代码只看返回值，于是不走键盘回退。
- 现在 AXSelectedText 写入后读 AXValue：能读到且写入前后不变（最多等 200 ms，`OPEN_COMPUTER_USE_SELECTED_TEXT_APPLY_MS`）就改用按键事件输入。值读不到，或用同样的文字替换同样的选中内容时，仍按原来的方式信任返回值。
- 结果：Chrome Amazon 搜索框和新标签页 Google 搜索框默认 `type_text` 都能输入，文字只出现一次；TextEdit 仍走 AX 写入（92 ms，没有回退）。新增单元测试 `testSelectedTextWriteThatChangesNothingFallsBackToKeys` 和实机测试 `TypeTextLiveTests`。`swift test` 488 个测试通过。

由 Claude Code（claude-opus-5-5）实现。
