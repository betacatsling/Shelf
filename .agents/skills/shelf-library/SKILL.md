---
name: shelf-library
description: >-
  Add, update, or query media records (games, novels/books/texts, movies/TV/anime/videos)
  in the user's macOS Shelf app (作品库). Use this skill whenever the user mentions Shelf,
  作品库, or asks to record, log, mark as playing/reading/watching, completed, unfinished,
  or add to backlog any game (游戏), book/novel/manga/text (文字/小说), or anime/movie/series (影像/番剧/电影/电视剧).
---

# Shelf（作品库）条目添加与维护指南

本技能用于向 macOS 原生应用 **Shelf（作品库）** 安全地添加或更新作品记录，保证双语名称准确、竖版海报清晰匹配、且不与运行中的客户端发生数据覆盖冲突。

- **数据文件**：`~/Library/Application Support/Shelf/library.json`
- **封面目录**：`~/Library/Application Support/Shelf/Covers/`
- **辅助脚本**：[shelf_cli.py](./scripts/shelf_cli.py)

---

## 一、收录范围与字段规范（要添加什么东西）

每条记录对应一个 `MediaItem`，包含以下核心字段：

### 1. 三大分类（`category`）与子标签（`subtag`）
| `category` 值 | 界面名称（中 / 英） | 适用内容范围 | 常用 `subtag`（不确定则留空 `""`） |
| :--- | :--- | :--- | :--- |
| `game` | 游戏 / Games | PC、主机、掌机、移动端等各类电子游戏 | `Steam`、`Switch`、`PS5`、`PC`、`移动端`（**禁止填 `"游戏"`**，避免与大类重复） |
| `novel` | 文字 / Texts | 网文/小说、实体书、非虚构、社科、文学、漫画、轻小说等阅读作品 | `小说`、`非虚构`、`社科`、`文学`、`漫画`、`轻小说`、`科幻` |
| `video` | 影像 / Videos | 电视剧、番剧/动画、电影、动画电影、纪录片等观看作品 | `番剧`、`电影`、`电视剧`、`纪录片`、`动画电影` |

### 2. 四种状态（`status`）映射规则
根据用户的自然表达选择对应状态：
- `active`（**进行中**：`正在玩` / `正在读` / `正在看`）：用户表示“最近在玩 / 正在看 / 在读 / 刚开坑”。
- `completed`（**已完成**：`已玩过` / `已读完` / `已看完`）：用户表示“打完了 / 通关了 / 看完了 / 读过了”。
- `unfinished`（**未完成**）：用户表示“玩了一半没打完 / 弃坑 / 搁置了 / 没看完”。
- `backlog`（**待开始**：`待玩` / `待读` / `待看`）：用户表示“想玩 / 想看 / 种草 / 先记到待玩列表”。

### 3. 中英双语标题规范（`title` 与 `titleEN`）
Shelf 支持一键切换 `中文 / English`，**严禁机翻或生造民间译名**：
- **`title`（中文名 / 主标题，必填）**：
  - 优先填写**官方简体中文译名**（例如 Steam 国区官中名：`Blue Prince` → `蓝途王子`，`and Roger` → `折言`，`Order of the Sinking Star` → `沉星之序`）。
  - 若该作品**没有官方简中译名**（如 `Last Call BBS`、`TUNIC`、`FEZ`、`ElecHead`），直接填写英文/日文**原名**。
- **`titleEN`（官方英文名，选填）**：
  - 填写该作品的**官方英文发行名称**（如 `诡秘之主` → `Lord of Mysteries`，`道诡异仙` → `Dao of the Bizarre Immortal`，`影之刃零` → `Phantom Blade Zero`）。
  - 若该作品**没有官方英文译名**（如《无尽债务》《诡秘地海》），**必须传空字符串 `""`**（客户端在英文模式下会自动回退显示 `title` 原名）。

### 4. 评分与备注（`rating` 与 `notes`）
- **`rating`**：`0`–`5` 整数。用户未明确给出星级时**一律保持 `0`（未评分）**，不要擅自打分。
- **`notes`**：
  - 用户口述了评价或分数（如 `总分 92`）则如实记录。
  - 用户未提评价时：`game` / `video` 保持空字符串 `""`；`novel`（文字类）如果新建且无备注，可简短注明作者（如 `Andlao 著`、`狐尾的笔 著`）。**严禁替用户编造主观长篇评价**。

---

## 二、标准操作流程（怎么添加 / 更新）

> **关键安全约束**：`Shelf.app` 在退出（`applicationWillTerminate`）时会把内存数据写回 `library.json`。**切勿在 `Shelf.app` 运行时直接手改 `library.json`**——请始终使用下方的 [shelf_cli.py](./scripts/shelf_cli.py)，它会自动先安全退出客户端、原子写入数据并重新打开客户端。

### 第 1 步：先查重（避免与待玩列表重复）
很多用户刚打完或刚开始玩的作品原本就已经在 `backlog`（待开始）列表中。添加前先检索现有库：

```bash
python3 .agents/skills/shelf-library/scripts/shelf_cli.py list -q "关键词"
```

- 如果已存在同名条目（且已有正确封面）：无需重新找图，直接跳到第 4 步用 `upsert` 更新其 `--status`（必要时补全 `--title-en`）。

### 第 2 步：核实官方双语名称与作者信息
若用户只给了模糊描述（如“乔纳森·布洛最新的游戏”、“赛博朋克动漫第二季”）或只给了单语名称：
1. 先用 `search_web` 确认准确作品名、是否有官方简中名与官方英文名。
2. 文字类作品顺便确认作者名。

### 第 3 步：获取高清竖版（`2:3`）封面链接
新条目必须配好竖版海报：
- **游戏 / 番剧 / 影视 / 出版书**：运行候选封面搜索：
  ```bash
  python3 .agents/skills/shelf-library/scripts/shelf_cli.py search-cover "作品名称" --category game
  ```
  - 游戏优先选用 Steam `library_600x900_2x.jpg` 官方竖版海报（若中文搜不到，改搜英文原名）。
  - 主机独占游戏（如 Switch / PS5）、动画番剧、实体书优先选用 Bangumi `large` 封面。
- **起点中文网连载/完结网文**：优先使用起点官方高清书封（将 `<bid>` 替换为起点书号，如 `1026938964`）：
  `https://bookcover.yuewen.com/qdbimg/349573/<bid>/600.webp`

### 第 4 步：执行 `upsert` 写入记录与封面
使用 `upsert` 子命令一次性完成安全退出客户端、去重合并、封面转码保存（JPEG）与客户端重启：

```bash
python3 .agents/skills/shelf-library/scripts/shelf_cli.py upsert \
  --title "无尽债务" \
  --title-en "" \
  --category novel \
  --status active \
  --subtag "小说" \
  --notes "Andlao 著" \
  --cover-url "https://bookcover.yuewen.com/qdbimg/349573/1026938964/600.webp"
```

如果是将库内已有的 `待玩` 作品更新为 `正在玩` 或 `已玩过`（保留原封面）：

```bash
python3 .agents/skills/shelf-library/scripts/shelf_cli.py upsert \
  --title "沉星之序" \
  --title-en "Order of the Sinking Star" \
  --category game \
  --status active
```

### 第 5 步：肉眼核验封面（必做！）
**严禁盲信搜索第 1 个结果！**（常见误匹配包括：原声带 OST / 设定集 Artbook、同系列错代如把初代配成第 3 代、短英文名误匹配如 `ATO` 误配 `Atomic Heart`）。

每当下载了新封面后，**必须调用 `read_file` 查看命令输出的 `COVER_PATH` 图片文件**：
- 确认画面确实是该作品本体的竖版海报；
- 若发现错配，立即更换准确的 `--cover-url`（或 `--cover-file`）重新执行一次 `upsert` 覆盖替换。
