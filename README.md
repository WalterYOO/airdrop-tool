# airdrop-tool

把文件通过 AirDrop 发送到指定设备，无需手动点击。包含两个 macOS 命令行工具，以及一个可直接安装的 agent skill。

```
airdrop  打开系统 AirDrop 面板，保持到分享结束
click    通过 Accessibility API 找到设备、触发发送、校验状态、关闭面板
```

## 为什么需要它

macOS 没有公开的 AirDrop API：

- `NSSharingService` 只能打开分享面板，无法选择目标设备。
- 合成鼠标事件（`CGEvent`）对面板里的设备行会被静默丢弃——设备列表是远程视图，不接收合成点击。
- 唯一可靠的方式是 Accessibility API 的 `AXPress` 动作。

这个项目把这套流程封装成了可脚本化、可验证的命令。

## 特性

- **按设备名定位**，不依赖屏幕坐标，面板动画不影响结果
- **真实状态校验**：读取设备行的状态（`Waiting…` → `Sending` → `Sent`），失败/超时/面板提前关闭会返回不同退出码
- **自动收尾**：发送完成后按下面板的关闭按钮，`airdrop` 进程及时退出，不会残留
- **大文件可用**：实测 539 MB 视频，iPad 约 20 秒、Mac 约 40 秒
- **本地化友好**：面板、设备行、关闭按钮都按结构识别，不匹配英文标题

## 要求

- macOS，已开启 AirDrop
- Xcode Command Line Tools：`xcode-select --install`
- 辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，勾选运行命令的终端（或 agent 宿主）
- 至少一台附近可发现的设备

## 安装

### 作为 agent skill

```bash
npx skills add WalterYOO/airdrop-tool -g -y
make -C ~/.agents/skills/airdrop-tool
```

安装后 Claude Code、Codex、Cursor、Gemini CLI 等可直接调用。二进制不随仓库分发（架构相关），安装后构建一次即可；`scripts/send.sh` 也会自动构建。

### 直接使用

```bash
git clone https://github.com/WalterYOO/airdrop-tool.git
make -C airdrop-tool/skills/airdrop-tool

airdrop-tool/skills/airdrop-tool/bin/airdrop ~/Pictures/photo.jpg &
airdrop-tool/skills/airdrop-tool/bin/click --device "Math的iPad"
```

## 用法

一条命令完成发送：

```bash
skills/airdrop-tool/scripts/send.sh "Math的iPad" ~/Pictures/photo.jpg
```

分步执行（可以同时发送多个文件或目录）：

```bash
bin/airdrop a.jpg b.mov dir/ &
bin/click --device "Math的iPad"
```

查看当前可见设备（需要面板已打开）：

```bash
bin/airdrop /tmp/probe.txt &
bin/click --list
kill $!
```

### click 参数

| 参数 | 说明 |
|---|---|
| `--device <name>` | 目标设备名，精确匹配优先，其次唯一子串匹配 |
| `--wait <sec>` | 等待设备出现的秒数，默认 10 |
| `--timeout <sec>` | 按下后的传输超时，默认 120，大文件请调大 |
| `--list` | 列出面板中的设备 |
| `--dry-run` | 只定位不发送 |
| `--keep-open` | 发送后不关闭面板 |
| `--pid <pid>` | 指定面板所属进程（重命名二进制时使用） |

### 退出码

| 命令 | 退出码 |
|---|---|
| `airdrop` | `0` 面板已关闭 / `1` 服务不可用或失败 / `2` 参数或路径错误 / `130` 用户取消 |
| `click` | `0` 已发送 / `1` 无辅助功能权限 / `2` 参数错误 / `3` 设备不存在或歧义 / `4` 发送失败或面板提前关闭 / `5` 超时 |

> `airdrop` 的 `0` 只表示面板关闭，不代表对方收到。判断是否送达请以 `click` 的 `sent` 为准。

## 工作原理

1. `airdrop` 通过 `NSSharingService(named: .sendViaAirDrop)` 打开分享面板。
2. `click` 用 libproc 找到可执行文件名为 `airdrop` 的进程，读取其 AX 窗口。
3. 面板按结构识别：包含 `AXScrollArea` 的窗口；设备行是滚动区内的 `AXButton`；关闭按钮是滚动区外的唯一按钮。
4. 对目标设备执行 `AXPress`，轮询其 `AXDescription` 的状态后缀。
5. 状态变为 `Sent` 后按关闭按钮，面板关闭，`airdrop` 退出。

## 限制

- `Sent` 是系统能提供的最强信号，没有公开的端到端回执。
- 成功/失败状态词目前识别英文和中文；未知状态会打印并继续等待，不会破坏设备名匹配。
- 依赖 AirDrop 面板的 AX 结构，若系统大版本改变结构需要更新 `scanDevices`。
- 仅支持 macOS。

## 目录结构

```
skills/airdrop-tool/
├── SKILL.md          # agent 使用说明
├── Makefile          # 编译 src/ → bin/
├── src/
│   ├── airdrop.swift
│   └── click.swift
└── scripts/send.sh   # 一条命令完成发送
```

## License

MIT © 2026 Walter LIU

