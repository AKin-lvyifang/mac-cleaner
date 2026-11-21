<p align="center"><img src="docs/icon.png" width="128"></p>

<h1 align="center">Mac Cleaner</h1>

<p align="center">常驻菜单栏、点一下就释放内存的 macOS 小工具。自身占用约 12 MB。</p>

---

## 为什么

电脑用久了会卡，通常不是「缓存没清」，而是一堆**已经不用、却还占着内存的进程**：关了窗口却没退出的 node / python / MCP 服务、闲置几小时的 AI Agent 会话、跑了好几天越吃越多的 Chrome 和飞书。Mac Cleaner 专门清这些，不做「清空系统缓存」这种只能好看几分钟的事。

## 用法

- **左键点图标**：立即清理，图标旁显示释放了多少（如 `−2.3 GB`）
- **右键**：查看上次清理明细 / 退出
- 图标变橙 / 变红：内存压力紧张 / 严重

## 清理什么

| 类别 | 规则 | 不碰 |
| --- | --- | --- |
| 残留后台进程 | 父进程已退出的 `node` `python` `npx` `uv` `bun` `deno` `claude` `codex` 等 | launchd 托管的服务、在监听端口的进程、启动不足 10 分钟的进程 |
| 闲置 AI 会话 | Claude 桌面版里 2 小时没有 CPU 活动的会话，连同其 MCP 子进程 | 正在工作的会话 |
| Chrome | 总占用 > 2 GB 且不在前台 → 退出并带 `--restore-last-session` 重开，标签页会恢复 | 正在前台使用时；麦克风在用（开会）时 |
| 飞书 / Lark | 总占用 > 1.2 GB 且不在前台 → 退出并重开 | 同上 |

阈值写在 `MacCleaner.swift` 开头，按需修改。

## 安装

需要 macOS 13+ 和 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/AKin-lvyifang/mac-cleaner.git
cd mac-cleaner
./build.sh
```

会安装到 `/Applications/Mac Cleaner.app`，并通过 LaunchAgent 设为开机自启。

先看看会清理什么、不真正动手：

```bash
"/Applications/Mac Cleaner.app/Contents/MacOS/MacCleaner" --dry-run
```

## 卸载

```bash
launchctl bootout gui/$(id -u)/io.github.maccleaner
rm ~/Library/LaunchAgents/io.github.maccleaner.plist
rm -rf "/Applications/Mac Cleaner.app"
```

## 注意

- Chrome 重启时，网页里未提交的表单内容会丢失。
- 「开会」通过「是否有程序在使用麦克风」判断。
- 只结束当前用户自己的进程，不需要管理员权限。

## License

MIT
