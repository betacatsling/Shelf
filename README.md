# Shelf（作品库）

一款原生 macOS 竖版海报墙作品记录工具（支持 **简体中文 / English** 一键切换），结合类似 Steam 库的海报陈列感与 macOS 原生界面风格，用来清爽地记录你体验过的 **游戏（Games）**、**文字（Texts）** 与 **影像（Videos）**。

A native macOS vertical-poster media tracker with one-click **简体中文 / English** switching, combining Steam Library-style `2:3` poster shelves with clean macOS UI aesthetics for tracking **Games**, **Texts**, and **Videos**.

## 下载安装 / Installation

前往 **[最新发布](https://github.com/betacatsling/Shelf/releases/latest)** 下载 Apple Silicon 安装包。

1. 双击打开 `.dmg` 镜像，将 **作品库（`Shelf.app`）** 拖入右侧 `Applications` 文件夹即可安装（要求 macOS 14.0+，Apple Silicon）。
2. 由于未附加付费开发者公证签名，若首次打开提示“无法验证开发者”，可在终端执行以下命令解除隔离属性后打开：
   ```bash
   xattr -cr /Applications/Shelf.app
   ```

## 核心特性 / Features

- **中英双语无缝切换（Bilingual Mode）**
  - 侧边栏底部或快捷键 `⌘L` 一键切换 **中文 / English**
  - 切换语言时，界面文案、分类标签与作品名称整体切换为对应语言；无官方译名的作品自动保留原名，右侧详情栏同步展示双语副标题
  - 顶部搜索框在任意语言下均同时支持检索中文名与英文名
- **清晰的导航与全键盘操控**
  - **左侧导航栏**：专注内容范围（`全部 ⌘1`、`游戏 ⌘2`、`文字 ⌘3`、`影像 ⌘4` 与精选 `五星作品 ⌘5`）
  - **顶部状态栏**：固定展示当前范围内的实时计数（`分栏` + `进行中 / 已完成 / 未完成 / 待开始`）
  - **全键盘支持**：海报墙支持方向键 `← → ↑ ↓` 移动选中、`Return` 快速编辑、`Esc` 或点击空白处收起右侧详情栏
- **`2:3` 原生竖版海报墙**
  - AppKit 海报墙复用可见区域和缓冲行的卡片，提前挂载图层并后台预取附近封面
  - 支持**分栏陈列**（折叠状态自动记忆）与**单一状态筛选**，支持按更新时间、添加时间、个人评分、作品名称正倒序排列
  - 底部缩放滑块与快捷键（`⌘+` / `⌘-` / `⌘0`）自由调整海报尺寸
- **清爽统一的封面管理**
  - 内置 **「更换封面 / Change Cover」** 面板：统一整合按作品名在线搜索（Steam / Bangumi / Apple，单击预览、双击应用）、本地选图、剪贴板粘贴与图片链接加载
  - 支持把图片文件或网页图片拖到任意海报卡片或详情封面上，后台处理后更新封面
- **评分、随笔与本地存储**
  - 单击海报展开/收起右侧详情面板，支持 1–5 星评分、切换状态与实时自动保存随笔评价
  - 纯本地存储，支持一键导出 / 导入 `.json` 备份文件（`⇧⌘E` / `⇧⌘I`）

## 本地数据目录 / Local Storage

- 记录数据：`~/Library/Application Support/Shelf/library.json`
- 原图封面：`~/Library/Application Support/Shelf/Covers/`
- 缩略图缓存：`~/Library/Application Support/Shelf/Thumbnails/`

## 从源码编译 / Build from Source

需要 macOS 14.0+ 及 Xcode 或 Command Line Tools：

```bash
git clone https://github.com/betacatsling/Shelf.git
cd Shelf
./build_app.sh   # 编译生成 Shelf.app
./build_dmg.sh   # 编译并打包生成 Shelf.dmg 安装镜像
open Shelf.app
```

## 开源协议 / License

本项目基于 [MIT License](./LICENSE) 开源。
