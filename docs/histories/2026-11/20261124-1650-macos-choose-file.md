# macOS choose_file：在打开面板里按路径选文件

用户需要让 OCU 在应用的打开文件面板里选文件（例如 3D 编辑器的导入面板）。打开面板的文件列表由独立的 Open and Save Panel Service 远程绘制，发给 app 的按键（⌘⇧G 前往文件夹）和指针点击（auto、sky_click）都到不了面板；只有无障碍操作能到。

改动：新增 macOS 工具 `choose_file(app, path)`。
- 先在 app 的窗口和 sheet 里找面板，依据是同时存在 `OKButton` 和 `where popup`。
- 从侧边栏里路径上方最深的位置开始：启动磁盘、应用程序、个人文件夹及其常用文件夹、已装载的卷。
- 对每层文件夹的名称单元格执行 `AXOpen`，再用 Where 弹出菜单确认面板已经进入该层。
- 到文件时设置行的 `AXSelected`，确认 Open 按钮可用后按下，再确认面板已关闭。
- 面板服务对 `AXOpen` 返回 kAXErrorActionUnsupported，但实际已经打开，所以不看返回值，只看 Where 的变化。
- 图标或分栏视图先通过 View Options 菜单（`cmdViewAsList:`，与语言无关）切到列表视图，结果里会说明这一点。
- 查找面板控件时用广度优先搜索，不进入文件列表和侧边栏，因为每次 AX 读取都要跨进程往返。实测从 22.5 s 降到 0.67 s。

拒绝的情况：
- 隐藏路径：点文件、/tmp、/private，面板不会列出它们。
- 文件夹。
- 保存面板：带 `saveAsNameTextField` 或标识含 save。
- Open 按钮保持禁用的文件，即类型不被接受的文件。
- app 位于其他 Space 或全屏 app 之后时，面板不加载文件，报错并提示先切换到该桌面。

验证：
- `FilePanelTests` 覆盖路径展开、锚点选择、行名与 Finder 显示名匹配、Where 匹配和 schema；工具数量测试更新为 13；`swift test` 全部通过。
- 真机（macOS 27.2，TextEdit 打开面板，后台运行，不发送按键和指针事件）：从 Documents 进入两层文件夹并打开文件，耗时 0.67 s；面板处于分栏视图时自动切换为列表视图，耗时 1.16 s；保存面板被拒绝。

由 Claude Code（claude-opus-5-5）实现，用户验证。
