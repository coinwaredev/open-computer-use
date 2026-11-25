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

由 Claude Code（claude-opus-5-5）实现。
