# macOS：后台指针输入（滚轮定点、任意键拖动、悬停）

游戏视图（Roblox Studio 视口）没有无障碍树，原来只能用全屏工具移动真实指针来缩放和转镜头。

## 改动

- 新增 `SkyPointerDispatcher`（`SkyPointerSimulation.swift`）：鼠标移动、按下/拖动/抬起和滚轮事件都盖上目标窗口的 SkyLight 字段（目标 pid、窗口号、指针下窗口、窗口内坐标）后经 `SLEventPostToPid` 投递。拖动沿用 `sky_click` 的目标侧合成焦点；悬停和滚轮不需要。
- 只走 SkyLight 一条通道。实测（自建 AppKit 记录窗口，后台）每个事件恰好到达一次。
- `scroll`：`element_index` 改为可选。给 `x`/`y` 时在截图坐标处发滚轮，都不给时在窗口中心发。每页 12 行，拆成每次最多 3 行的刻度，因为游戏每个滚轮事件缩放一次。
- `drag`：新增 `mouse_button`（left/right/middle）、`duration_ms`（默认 250）和 `drag_method`（auto/sky/app_post/global）。auto 先 sky 后 app_post；设置了 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 时仍走 global。每个拖动事件带整像素增量，按取整后的位置相减，总和等于全程距离（镜头读增量，不读位置）。app_post 和 global 路径也支持左右中键。
- 新工具 `hover`：按元素或截图坐标移动指针、不按键，等 150 ms（`OPEN_COMPUTER_USE_HOVER_SETTLE_MS`）后读回。
- sky 拖动和定点滚轮读回前等 100 ms（`OPEN_COMPUTER_USE_POINTER_READ_BACK_MS`）：Chrome 立即读回时四个滚轮刻度只画了一个。

## 实测

- AppKit 记录窗口（后台，经已安装应用的 CLI）：悬停 2 个 moved；右键拖动 1 down + 38 dragged + 1 up，dx 总和 150 pt，正好等于 300 px（2x）；滚轮 1 页 4 个刻度、0.5 页 2 个；左键拖动落地。前台应用和真实指针都没有变化。
- Chrome：滚轮在被遮挡时也落地。被遮挡的窗口隐藏页面，鼠标移动在它进入视野一次前被丢弃（已有限制）。拖动时 Chrome 的 `event.buttons` 为 0，因为它读真实硬件按键状态；从 mousedown 开始跟踪的页面可用，逐次检查 buttons 的页面不行。
- Roblox Studio（Play 模式，Studio 在后台，读客户端相机）：
  - 定点滚轮把游戏相机从 18.4 拉近到 13.9 studs。
  - 右键拖动 300 px 转动相机约 25°，重复稳定。Roblox 转镜头时锁定鼠标，把真实指针 warp 到按下点，并且有一次把 Studio 拉到前台。现在拖动结束后，如果真实指针正好停在本次拖动发出的某个点上，就移回原位（用户自己移动的指针不动）；目标应用抢到前台时把原前台应用激活回来。结果里都会附说明。实测指针回到原位（误差 1 pt），前台保持不变。
  - 左键拖动能转动角色创建器里的"拖动旋转"预览。
  - 悬停无效：Studio 是 Qt 应用，Qt 只把移动事件交给它认为在真实指针下的窗口（由 WindowServer 的进入/离开跟踪决定）。加合成焦点、再加合成 key window 都试过，仍无效。

## 测试

- `PointerInputTests`：路径、滚轮刻度、投递顺序、参数解析、schema、错误文本。
- `PointerLiveTests`（`OCU_LIVE_POINTER_PID`、`OCU_LIVE_POINTER_TITLE`、`OCU_LIVE_POINTER_STEPS`）：直接驱动真实窗口，并断言前台应用和真实指针不变。
