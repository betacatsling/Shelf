# Shelf（作品库）

一款原生 macOS 竖版海报墙作品记录工具（支持 **简体中文 / English** 一键切换），结合类似 Steam 库的海报陈列感与 macOS 原生界面风格，用来清爽地记录你体验过的 **游戏（Games）**、**文字（Texts）** 与 **影像（Videos）**。

A native macOS vertical-poster media tracker with one-click **简体中文 / English** switching, combining Steam Library-style `2:3` poster shelves with clean macOS UI aesthetics for tracking **Games**, **Texts**, and **Videos**.

## 下载安装 / Installation

前往 **[Releases](https://github.com/betacatsling/Shelf/releases)** 下载最新版本的安装包（如 `Shelf-v1.1.0-macOS-arm64.zip`）：

1. 解压得到 `Shelf.app`（显示名称：**作品库**），拖入「应用程序（Applications）」文件夹即可使用（要求 macOS 14.0+，Apple Silicon）。
2. 由于未附加付费开发者公证签名，若首次打开提示“无法验证开发者”，可在终端执行以下命令解除隔离属性后打开：
   ```bash
   xattr -cr /Applications/Shelf.app
   ```

## 核心特性 / Features

- **中英双语无缝切换（Bilingual Mode）**
  - 侧边栏底部或快捷键 `⌘L` 一键切换 **中文 / English**
  - 切换语言时，界面文案、分类标签与作品名称整体切换为对应语言；无官方译名的作品自动保留原名，避免同屏中英混杂
  - 顶部搜索框在任意语言下均同时支持检索中文名与英文名
- **三大分类 · 四种状态**
  - **分类**：`游戏 / Games`（`⌘2`）、`文字 / Texts`（小说、非虚构、社科、漫画等，`⌘3`）、`影像 / Videos`（电影、剧集、番剧、纪录片等，`⌘4`）
  - **状态**：
    - **进行中 / In Progress**（按分类自动显示 `正在玩 / Playing`、`正在读 / Reading`、`正在看 / Watching`）
    - **已完成 / Completed**（`已玩过 / Played`、`已读完 / Finished`、`已看完 / Watched`）
    - **未完成 / Unfinished**
    - **待开始 / Backlog**（`待玩 / Backlog`、`待读 / To Read`、`待看 / Watchlist`）
- **`2:3` 竖版海报墙**
  - 预解码双层位图缓存与离屏渲染优化，百余张高清海报依然保持高帧率顺滑滚动
  - 支持**分栏陈列**与**单一状态筛选**，支持按更新时间、添加时间、个人评分、作品名称正倒序排列
  - 底部缩放滑块与快捷键（`⌘+` / `⌘-` / `⌘0`）自由调整海报尺寸
- **多种封面替换方式**
  - 内置 **「更换封面 / Change Cover」** 面板：支持按作品名在线搜索高清竖版封面（单击预览裁剪效果、双击直接应用）
  - 支持**选择本地图片**、**粘贴剪贴板图片/截图**、**输入图片网络链接**，或直接将图片文件拖到任意海报卡片上秒换封面
- **评分、随笔与本地存储**
  - 单击海报展开右侧详情面板，支持 1–5 星评分、切换状态与实时自动保存随笔评价
  - 纯本地存储，支持一键导出 / 导入 `.json` 备份文件（`⇧⌘E` / `⇧⌘I`）

## 本地数据目录 / Local Storage

- 记录数据：`~/Library/Application Support/Shelf/library.json`
- 封面缓存：`~/Library/Application Support/Shelf/Covers/`

## 从源码编译 / Build from Source

需要 macOS 14.0+ 及 Xcode 或 Command Line Tools：

```bash
git clone https://github.com/betacatsling/Shelf.git
cd Shelf
./build_app.sh
open Shelf.app
```

## 开源协议 / License

本项目基于 [MIT License](./LICENSE) 开源。
