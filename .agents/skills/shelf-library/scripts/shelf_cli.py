#!/usr/bin/env python3
"""
Helper CLI for reading and updating Shelf (作品库) on macOS and Linux.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from pathlib import Path

LINUX = sys.platform.startswith("linux")
CUSTOM_DATA_DIR = os.environ.get("SHELF_DATA_DIR")
if LINUX:
    try:
        from shelf.library import data_root
    except ModuleNotFoundError:
        # Source checkout. The installed launcher already sets PYTHONPATH.
        sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "linux"))
        from shelf.library import data_root
    BASE_DIR = str(data_root())
else:
    BASE_DIR = os.path.expanduser(CUSTOM_DATA_DIR or "~/Library/Application Support/Shelf")
LIB_PATH = os.path.join(BASE_DIR, "library.json")
TAGS_PATH = os.path.join(BASE_DIR, "tags.json")
COVERS_DIR = os.path.join(BASE_DIR, "Covers")
THUMBS_DIR = os.path.join(BASE_DIR, "Thumbnails")

VALID_CATEGORIES = ("game", "novel", "video")
VALID_STATUSES = ("active", "completed", "unfinished", "backlog")

DEFAULT_STARTER_TAGS = (
    "Steam",
    "Switch",
    "PS5",
    "PC",
    "移动端",
    "小说",
    "非虚构",
    "社科",
    "文学",
    "漫画",
    "轻小说",
    "科幻",
    "电影",
    "电视剧",
    "番剧",
    "纪录片",
    "动画电影",
)

STARTER_GROUPS = (
    ("平台", ("Steam", "Switch", "PS5", "PC", "移动端")),
    ("体裁", ("小说", "非虚构", "社科", "文学", "漫画", "轻小说", "科幻")),
    ("形式", ("电影", "电视剧", "番剧", "纪录片", "动画电影")),
)

STARTER_PARENT_BY_TAG = {
    child.lower(): parent
    for parent, children in STARTER_GROUPS
    for child in children
}

ZH_TO_EN_TAGS = {
    "平台": "Platform",
    "体裁": "Genre",
    "形式": "Format",
    "移动端": "Mobile",
    "小说": "Novel",
    "非虚构": "Non-Fiction",
    "社科": "Social Science",
    "文学": "Literature",
    "漫画": "Manga",
    "轻小说": "Light Novel",
    "科幻": "Sci-Fi",
    "电影": "Movie",
    "电视剧": "TV Series",
    "番剧": "Anime",
    "纪录片": "Documentary",
    "动画电影": "Animated Film",
}
EN_TO_ZH_TAGS = {en.lower(): zh for zh, en in ZH_TO_EN_TAGS.items()}
CANONICAL_TAG_LOOKUP = {
    **{t.lower(): t for t in DEFAULT_STARTER_TAGS},
    **{zh.lower(): zh for zh in ZH_TO_EN_TAGS},
    **{en.lower(): zh for zh, en in ZH_TO_EN_TAGS.items()},
}


def canonical_tag(raw: str) -> str:
    s = (raw or "").strip()
    if not s:
        return ""
    return CANONICAL_TAG_LOOKUP.get(s.lower(), s)


def tags_match(lhs: str, rhs: str) -> bool:
    a = canonical_tag(lhs)
    b = canonical_tag(rhs)
    return bool(a and b and a.lower() == b.lower())


def normalize_tags(raw_tags: list[str]) -> list[str]:
    seen = set()
    result = []
    for raw in raw_tags:
        tag = canonical_tag(raw)
        if not tag:
            continue
        key = tag.lower()
        if key not in seen:
            seen.add(key)
            result.append(tag)
    return result


def split_tag_values(values: list[str] | str | None) -> list[str]:
    if values is None:
        return []
    raw_list = [values] if isinstance(values, str) else values
    pieces = []
    for raw in raw_list:
        for part in re.split(r"[,，;；]", raw):
            part = part.strip()
            if part:
                pieces.append(part)
    return pieces


def get_item_tags(item: dict) -> list[str]:
    raw_tags = item.get("tags")
    if isinstance(raw_tags, list):
        return normalize_tags([str(t) for t in raw_tags])
    subtag = (item.get("subtag") or "").strip()
    return normalize_tags([subtag]) if subtag else []


def set_item_tags(item: dict, tags: list[str]):
    normalized = normalize_tags(tags)
    item["tags"] = normalized
    item["subtag"] = normalized[0] if normalized else ""


def is_shelf_running() -> bool:
    res = subprocess.run(["pgrep", "-x", "Shelf"], capture_output=True)
    return res.returncode == 0


def find_shelf_app_bundle() -> str | None:
    candidates = [
        "/Applications/Shelf.app",
        os.path.expanduser("~/Applications/Shelf.app"),
        os.path.expanduser("~/Desktop/Shelf/Shelf.app"),
    ]
    for c in candidates:
        if os.path.isdir(c):
            return c
    res = subprocess.run(
        ["mdfind", "kMDItemCFBundleIdentifier == 'com.local.shelf.mediatracker'"],
        capture_output=True,
        text=True,
    )
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.endswith(".app") and os.path.isdir(line):
            return line
    return None


def quit_shelf_safely() -> bool:
    """Wait for Shelf to finish saving and exit before editing library.json."""
    if not is_shelf_running():
        return False
    subprocess.run(["pkill", "-x", "Shelf"], capture_output=True)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if not is_shelf_running():
            return True
        time.sleep(0.1)
    raise SystemExit("Shelf is still running. Close it before updating the library.")


def relaunch_shelf_if_possible():
    if LINUX:
        subprocess.Popen([sys.executable, "-m", "shelf", "--data-dir", BASE_DIR],
                         env={**os.environ, "PYTHONPATH": os.pathsep.join(sys.path)}, start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    app_path = find_shelf_app_bundle()
    if app_path:
        subprocess.run(["open", app_path], check=False)


def load_items() -> list[dict]:
    os.makedirs(COVERS_DIR, exist_ok=True)
    if not os.path.exists(LIB_PATH):
        return []
    with open(LIB_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def default_starter_categories() -> list[str]:
    return [cat for cat, _ in STARTER_GROUPS]


def default_starter_nodes() -> list[dict]:
    nodes = []
    for cat, children in STARTER_GROUPS:
        for child in children:
            nodes.append({"name": child, "category": cat, "parent": None})
    return nodes


def normalize_categories(raw_categories: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for raw in raw_categories:
        canon = canonical_tag(str(raw))
        if not canon:
            continue
        key = canon.lower()
        if key in seen:
            continue
        seen.add(key)
        result.append(canon)
    return result


def migrate_legacy_tags(flat_tags: list[str]) -> tuple[list[str], list[dict]]:
    categories: list[str] = []
    seen_cats: set[str] = set()
    result: list[dict] = []
    seen: set[str] = set()
    starter_cat_ids = {cat.lower() for cat, _ in STARTER_GROUPS}

    for raw in flat_tags:
        canonical = canonical_tag(str(raw))
        if not canonical:
            continue
        key = canonical.lower()
        if key in starter_cat_ids:
            if key not in seen_cats:
                seen_cats.add(key)
                categories.append(canonical)
            continue
        if key in seen:
            continue
        seen.add(key)
        group_cat = STARTER_PARENT_BY_TAG.get(key)
        if group_cat:
            if group_cat.lower() not in seen_cats:
                seen_cats.add(group_cat.lower())
                categories.append(group_cat)
            result.append({"name": canonical, "category": group_cat, "parent": None})
        else:
            result.append({"name": canonical, "category": None, "parent": None})
    return normalize_tag_catalog(categories, result)


def normalize_tag_catalog(
    raw_categories: list[str],
    nodes: list[dict],
    item_tags: list[str] | None = None,
) -> tuple[list[str], list[dict]]:
    categories = normalize_categories(raw_categories)
    cat_by_id = {c.lower(): c for c in categories}

    result: list[dict] = []
    seen: set[str] = set()

    for node in nodes:
        if not isinstance(node, dict):
            continue
        canonical = canonical_tag(str(node.get("name", "")))
        if not canonical:
            continue
        key = canonical.lower()
        if key in seen:
            continue
        seen.add(key)
        raw_cat = node.get("category")
        clean_cat = cat_by_id.get(canonical_tag(str(raw_cat)).lower()) if raw_cat is not None else None
        raw_parent = node.get("parent")
        clean_parent = canonical_tag(str(raw_parent)) if raw_parent is not None else ""
        if not clean_parent or tags_match(canonical, clean_parent):
            clean_parent = None
        result.append({"name": canonical, "category": clean_cat, "parent": clean_parent})

    for raw in item_tags or []:
        canonical = canonical_tag(str(raw))
        if not canonical:
            continue
        key = canonical.lower()
        if key in seen:
            continue
        seen.add(key)
        starter_cat = STARTER_PARENT_BY_TAG.get(key)
        valid_cat = cat_by_id.get(starter_cat.lower()) if starter_cat else None
        result.append({"name": canonical, "category": valid_cat, "parent": None})

    canonical_by_id = {n["name"].lower(): n["name"] for n in result}
    for n in result:
        parent = n.get("parent")
        if not parent:
            n["parent"] = None
            continue
        pid = parent.lower()
        if pid == n["name"].lower() or pid not in canonical_by_id:
            n["parent"] = None
        else:
            n["parent"] = canonical_by_id[pid]

    node_by_id = {n["name"].lower(): n for n in result}
    for n in result:
        visited = {n["name"].lower()}
        curr = n.get("parent")
        while curr:
            pid = curr.lower()
            if pid in visited:
                n["parent"] = None
                break
            visited.add(pid)
            parent_node = node_by_id.get(pid)
            curr = parent_node.get("parent") if parent_node else None

    for n in result:
        if n.get("parent"):
            cursor = n
            visited = {cursor["name"].lower()}
            while cursor.get("parent"):
                pid = cursor["parent"].lower()
                if pid in visited or pid not in node_by_id:
                    break
                visited.add(pid)
                cursor = node_by_id[pid]
            n["category"] = cursor.get("category")

    return categories, result


def normalize_tag_nodes(nodes: list[dict], item_tags: list[str] | None = None) -> list[dict]:
    _, normalized = normalize_tag_catalog([], nodes, item_tags=item_tags)
    return normalized


def children_of(parent_name: str | None, nodes: list[dict]) -> list[dict]:
    if parent_name is None:
        return [n for n in nodes if not n.get("parent")]
    target_id = canonical_tag(parent_name).lower()
    if not target_id:
        return []
    return [n for n in nodes if (n.get("parent") or "").lower() == target_id]


def descendants_of(tag_name: str, nodes: list[dict]) -> list[str]:
    root_id = canonical_tag(tag_name).lower()
    if not root_id:
        return []
    visited = {root_id}
    result: list[str] = []

    def walk(curr_parent: str):
        for child in children_of(curr_parent, nodes):
            cid = child["name"].lower()
            if cid in visited:
                continue
            visited.add(cid)
            result.append(child["name"])
            walk(child["name"])

    walk(tag_name)
    return result


def expanded_family(tag_name: str, nodes: list[dict]) -> list[str]:
    matched = next((n["name"] for n in nodes if tags_match(n["name"], tag_name)), None)
    canonical = matched or canonical_tag(tag_name)
    if not canonical:
        return []
    return [canonical] + descendants_of(canonical, nodes)


def can_set_parent(tag_name: str, new_parent: str | None, nodes: list[dict]) -> bool:
    canon_tag = canonical_tag(tag_name)
    if not canon_tag or not any(tags_match(n["name"], canon_tag) for n in nodes):
        return False
    if new_parent is None:
        return True
    canon_parent = canonical_tag(new_parent)
    if not canon_parent or not any(tags_match(n["name"], canon_parent) for n in nodes):
        return False
    if tags_match(canon_tag, canon_parent):
        return False
    return not any(tags_match(d, canon_parent) for d in descendants_of(canon_tag, nodes))


def flattened_outline(nodes: list[dict]) -> list[tuple[dict, int, list[str]]]:
    result: list[tuple[dict, int, list[str]]] = []
    visited: set[str] = set()

    def walk(parent_name: str | None, depth: int, ancestors: list[str]):
        for node in children_of(parent_name, nodes):
            nid = node["name"].lower()
            if nid in visited:
                continue
            visited.add(nid)
            result.append((node, depth, ancestors))
            walk(node["name"], depth + 1, ancestors + [node["name"]])

    walk(None, 0, [])
    return result


def load_tag_catalog(items: list[dict]) -> tuple[list[str], list[dict]]:
    if os.path.exists(TAGS_PATH):
        try:
            with open(TAGS_PATH, "r", encoding="utf-8") as f:
                raw = json.load(f)
            if isinstance(raw, dict) and isinstance(raw.get("nodes"), list):
                version = raw.get("version", 2)
                raw_cats = raw.get("categories", []) if isinstance(raw.get("categories"), list) else []
                raw_nodes = raw["nodes"]
                if version < 3:
                    starter_map = {cat.lower(): cat for cat, _ in STARTER_GROUPS}
                    promoted = {}
                    for n in raw_nodes:
                        if isinstance(n, dict) and not n.get("parent"):
                            nid = canonical_tag(str(n.get("name", ""))).lower()
                            if nid in starter_map:
                                promoted[nid] = starter_map[nid]
                                raw_cats.append(starter_map[nid])
                    if promoted:
                        migrated_nodes = []
                        for n in raw_nodes:
                            if not isinstance(n, dict):
                                continue
                            nid = canonical_tag(str(n.get("name", ""))).lower()
                            if nid in promoted:
                                continue
                            copy = dict(n)
                            parent_id = canonical_tag(str(copy.get("parent") or "")).lower()
                            if parent_id in promoted:
                                copy["parent"] = None
                                copy["category"] = promoted[parent_id]
                            migrated_nodes.append(copy)
                        raw_nodes = migrated_nodes
                cats, base = raw_cats, raw_nodes
            elif isinstance(raw, list):
                cats, base = migrate_legacy_tags([str(t) for t in raw])
            else:
                cats, base = default_starter_categories(), default_starter_nodes()
        except Exception:
            cats, base = default_starter_categories(), default_starter_nodes()
    else:
        cats, base = default_starter_categories(), default_starter_nodes()
    item_tags = [t for item in items for t in get_item_tags(item)]
    return normalize_tag_catalog(cats, base, item_tags=item_tags)


def load_tag_nodes(items: list[dict]) -> list[dict]:
    _, nodes = load_tag_catalog(items)
    return nodes


def save_tag_catalog(categories: list[str], nodes: list[dict]):
    os.makedirs(BASE_DIR, exist_ok=True)
    serialized = []
    for node in nodes:
        entry = {"name": node["name"]}
        if node.get("category"):
            entry["category"] = node["category"]
        if node.get("parent"):
            entry["parent"] = node["parent"]
        serialized.append(entry)
    payload = {"version": 3, "categories": categories, "nodes": serialized}
    tmp_path = TAGS_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp_path, TAGS_PATH)


def save_items(items: list[dict]):
    os.makedirs(BASE_DIR, exist_ok=True)
    if LINUX:
        from shelf.library import write_items
        write_items(Path(LIB_PATH), items, pretty=True)
        return
    tmp_path = LIB_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp_path, LIB_PATH)


def save_cover_image(source_url: str | None, source_file: str | None) -> str:
    if LINUX:
        from shelf.artwork import import_image, save_cover
        source = source_url if source_url else Path(source_file).expanduser()
        return save_cover(Path(BASE_DIR), import_image(source))
    os.makedirs(COVERS_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmpdir:
        raw_path = os.path.join(tmpdir, "raw_input")
        if source_url:
            subprocess.run(
                [
                    "curl",
                    "-sSL",
                    "--retry",
                    "2",
                    "--max-time",
                    "20",
                    "-A",
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15",
                    source_url,
                    "-o",
                    raw_path,
                ],
                check=True,
            )
        elif source_file:
            expanded = os.path.expanduser(source_file)
            if not os.path.isfile(expanded):
                raise FileNotFoundError(f"Cover file not found: {expanded}")
            shutil.copy2(expanded, raw_path)
        else:
            raise ValueError("Either source_url or source_file is required")

        if not os.path.exists(raw_path) or os.path.getsize(raw_path) < 512:
            raise RuntimeError("Downloaded/copied image is empty or invalid")

        cover_name = f"cover-{uuid.uuid4().hex.upper()}.jpg"
        dest_path = os.path.join(COVERS_DIR, cover_name)
        subprocess.run(
            [
                "sips",
                "-Z",
                "960",
                "-s",
                "format",
                "jpeg",
                "-s",
                "formatOptions",
                "90",
                raw_path,
                "--out",
                dest_path,
            ],
            check=True,
            capture_output=True,
        )
        return cover_name


def curl_json(url: str, method: str = "GET", json_body: dict | None = None) -> dict:
    cmd = [
        "curl",
        "-sSL",
        "--max-time",
        "10",
        "-X",
        method,
        "-H",
        "User-Agent: ShelfLibrary/1.2 (https://github.com/betacatsling/Shelf)",
    ]
    if json_body is not None:
        cmd.extend(["-H", "Content-Type: application/json", "-d", json.dumps(json_body)])
    cmd.append(url)
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0 or not res.stdout.strip():
        return {}
    try:
        return json.loads(res.stdout)
    except Exception:
        return {}


def cmd_list(args):
    items = load_items()
    nodes = load_tag_nodes(items)
    q = (args.query or "").strip().lower()
    tag_filter = (args.tag or "").strip()
    tag_family = expanded_family(tag_filter, nodes) if tag_filter else []
    matched = []
    for item in items:
        if args.category and item.get("category") != args.category:
            continue
        if args.status and item.get("status") != args.status:
            continue
        item_tags = get_item_tags(item)
        if args.untagged and item_tags:
            continue
        if tag_family and not any(tags_match(t, cand) for t in item_tags for cand in tag_family):
            continue
        if q:
            expanded_tags = []
            for t in item_tags:
                expanded_tags.append(t)
                if t in ZH_TO_EN_TAGS:
                    expanded_tags.append(ZH_TO_EN_TAGS[t])
                if t.lower() in EN_TO_ZH_TAGS:
                    expanded_tags.append(EN_TO_ZH_TAGS[t.lower()])
            hay = " | ".join(
                [
                    item.get("title", ""),
                    item.get("titleEN", ""),
                    *expanded_tags,
                    item.get("notes", ""),
                ]
            ).lower()
            if q not in hay:
                continue
        matched.append(item)

    print(f"Matched {len(matched)} / {len(items)} total items:")
    for x in matched[: args.limit]:
        has_cover = "yes" if x.get("coverFileName") else "NO"
        tags_str = ", ".join(get_item_tags(x))
        print(
            f"- id={x['id']} | {x['category']} | {x['status']} | "
            f"ZH={x.get('title','')} | EN={x.get('titleEN','')} | "
            f"tags=[{tags_str}] | rating={x.get('rating',0)} | cover={has_cover}"
        )


def cmd_search_cover(args):
    kw = args.query.strip()
    cat = args.category
    candidates = []

    # 1. Steam official 600x900 vertical posters (for games or all)
    if cat in (None, "game"):
        for lang, cc in [("schinese", "CN"), ("english", "US")]:
            enc = urllib.parse.quote(kw)
            sdata = curl_json(
                f"https://store.steampowered.com/api/storesearch/?term={enc}&l={lang}&cc={cc}"
            )
            raw_items = sdata.get("items") or []
            if raw_items:
                top_ids = [{"appid": it["id"]} for it in raw_items[:6]]
                inp = urllib.parse.quote(
                    json.dumps(
                        {
                            "ids": top_ids,
                            "context": {"language": lang, "country_code": cc},
                            "data_request": {"include_assets": True},
                        }
                    )
                )
                bdata = curl_json(
                    f"https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json={inp}"
                )
                for si in (bdata.get("response") or {}).get("store_items") or []:
                    assets = si.get("assets") or {}
                    fmt = assets.get("asset_url_format")
                    f2x = assets.get("library_capsule_2x") or assets.get("library_capsule")
                    if fmt and f2x:
                        full_url = (
                            "https://shared.akamai.steamstatic.com/store_item_assets/"
                            + fmt.replace("${FILENAME}", f2x)
                        )
                        candidates.append(
                            {
                                "source": f"Steam ({lang}, appid={si.get('appid')})",
                                "title": si.get("name", ""),
                                "url": full_url,
                            }
                        )
                break

    # 2. Bangumi v0 search (1=Book/Novel, 2=Anime, 4=Game, 6=Live-Action)
    bgm_types = {
        "game": [4],
        "novel": [1],
        "video": [2, 6],
        None: [1, 2, 4, 6],
    }[cat]
    bgm = curl_json(
        "https://api.bgm.tv/v0/search/subjects?limit=8",
        method="POST",
        json_body={"keyword": kw, "filter": {"type": bgm_types}},
    )
    for sub in bgm.get("data") or []:
        large = (sub.get("images") or {}).get("large")
        if large:
            candidates.append(
                {
                    "source": f"Bangumi (id={sub.get('id')})",
                    "title": f"{sub.get('name_cn') or ''} / {sub.get('name') or ''}".strip(" /"),
                    "url": large,
                }
            )

    # 3. Apple Books / Movies supplement
    if cat in ("novel", "video"):
        media = "ebook" if cat == "novel" else "movie"
        enc = urllib.parse.quote(kw)
        adata = curl_json(
            f"https://itunes.apple.com/search?term={enc}&country=CN&media={media}&limit=5"
        )
        for it in adata.get("results") or []:
            art = it.get("artworkUrl100")
            if art:
                candidates.append(
                    {
                        "source": f"Apple ({media})",
                        "title": it.get("trackName", ""),
                        "url": art.replace("100x100bb", "900x900bb"),
                    }
                )

    seen = set()
    deduped = []
    for c in candidates:
        if c["url"] not in seen:
            seen.add(c["url"])
            deduped.append(c)

    print(f"Found {len(deduped)} cover candidates for '{kw}':")
    for idx, c in enumerate(deduped, 1):
        print(f"[{idx}] {c['source']} | {c['title']}\n    {c['url']}")


def run_with_library_lock(open_after: bool, fn):
    was_running = False
    try:
        if LINUX:
            from shelf.lifecycle import cli_write_lock
            with cli_write_lock(Path(BASE_DIR)) as was_running:
                return fn()
        elif CUSTOM_DATA_DIR:
            return fn()
        else:
            was_running = quit_shelf_safely()
            return fn()
    finally:
        if was_running or open_after:
            relaunch_shelf_if_possible()


def cmd_upsert(args):
    run_with_library_lock(args.open, lambda: write_upsert(args))


def write_upsert(args):
    items = load_items()
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    title_zh = args.title.strip()
    title_en = (args.title_en or "").strip()
    if not title_zh and not title_en:
        print("Error: --title is required", file=sys.stderr)
        sys.exit(1)
    if not title_zh:
        title_zh = title_en

    # Match existing item by --id, exact title, or exact titleEN (within same category if provided)
    target = None
    for item in items:
        if args.id and item.get("id") == args.id:
            target = item
            break
        if item.get("category") == args.category:
            cur_zh = (item.get("title") or "").strip().lower()
            cur_en = (item.get("titleEN") or "").strip().lower()
            if cur_zh and cur_zh == title_zh.lower():
                target = item
                break
            if title_en and cur_en and cur_en == title_en.lower():
                target = item
                break
            if title_en and cur_zh and cur_zh == title_en.lower():
                target = item
                break

    new_cover_name = None
    old_cover = None
    if args.cover_url or args.cover_file:
        new_cover_name = save_cover_image(args.cover_url, args.cover_file)

    current_tags = get_item_tags(target) if target is not None else []
    if args.tags is not None:
        next_tags = normalize_tags(split_tag_values(args.tags))
    elif args.subtag is not None:
        next_tags = normalize_tags(split_tag_values(args.subtag))
    else:
        next_tags = list(current_tags)

    if args.add_tag:
        next_tags = normalize_tags(next_tags + split_tag_values(args.add_tag))
    if args.remove_tag:
        to_remove = split_tag_values(args.remove_tag)
        next_tags = [t for t in next_tags if not any(tags_match(t, r) for r in to_remove)]

    if target is not None:
        action = "UPDATED"
        target["title"] = title_zh
        if args.title_en is not None:
            target["titleEN"] = title_en
        target["category"] = args.category
        target["status"] = args.status
        set_item_tags(target, next_tags)
        if args.rating is not None:
            target["rating"] = max(0, min(5, args.rating))
        if args.notes is not None:
            target["notes"] = args.notes
        if new_cover_name:
            old_cover = target.get("coverFileName")
            target["coverFileName"] = new_cover_name
        target["updatedAt"] = now_iso
        target["isSample"] = False
        entry = target
    else:
        action = "ADDED"
        entry = {
            "id": str(uuid.uuid4()).upper(),
            "title": title_zh,
            "titleEN": title_en,
            "category": args.category,
            "status": args.status,
            "rating": max(0, min(5, args.rating if args.rating is not None else 0)),
            "notes": args.notes if args.notes is not None else "",
            "coverFileName": new_cover_name,
            "paletteSeed": random.randint(0, 999),
            "createdAt": now_iso,
            "updatedAt": now_iso,
            "isSample": False,
        }
        set_item_tags(entry, next_tags)
        items.insert(0, entry)

    save_items(items)
    nodes = load_tag_nodes(items)
    save_tag_nodes(nodes)

    if (old_cover and old_cover == os.path.basename(old_cover) and old_cover not in (".", "..")
            and not any(item.get("coverFileName") == old_cover for item in items)):
        for folder in (COVERS_DIR, THUMBS_DIR):
            try:
                os.remove(os.path.join(folder, old_cover))
            except FileNotFoundError:
                pass

    cover_fn = entry.get("coverFileName")
    cover_abs = os.path.join(COVERS_DIR, cover_fn) if cover_fn else None
    print(
        f"{action}: id={entry['id']} | {entry['category']} | {entry['status']} | "
        f"ZH={entry['title']} | EN={entry.get('titleEN','')} | tags=[{', '.join(entry.get('tags', []))}]"
    )
    if cover_abs:
        print(f"COVER_PATH: {cover_abs}")
    else:
        print("COVER_PATH: NONE (Warning: no cover image attached yet!)")


def cmd_tags_list(args):
    items = load_items()
    categories, nodes = load_tag_catalog(items)
    untagged_count = sum(1 for item in items if not get_item_tags(item))
    print(f"Managed tags ({len(nodes)} tag(s), {len(categories)} category(ies), {untagged_count} untagged item(s)):")
    cat_ids = {c.lower() for c in categories}

    def print_section(title: str, section_nodes: list[dict]):
        print(f"[{title}]")
        for node, depth, _ in flattened_outline(section_nodes):
            family = expanded_family(node["name"], nodes)
            count = sum(
                1
                for item in items
                if any(tags_match(t, cand) for t in get_item_tags(item) for cand in family)
            )
            en_hint = ZH_TO_EN_TAGS.get(node["name"])
            label = f"{node['name']} ({en_hint})" if en_hint else node["name"]
            indent = "  " * depth
            print(f"{indent}- {label}: {count} item(s)")

    for cat in categories:
        en_cat = ZH_TO_EN_TAGS.get(cat)
        cat_label = f"{cat} ({en_cat})" if en_cat else cat
        cat_nodes = [n for n in nodes if (n.get("category") or "").lower() == cat.lower()]
        print_section(cat_label, cat_nodes)

    uncat_nodes = [n for n in nodes if not n.get("category") or n["category"].lower() not in cat_ids]
    if uncat_nodes:
        print_section("未分类 (Uncategorized)", uncat_nodes)


def write_tags_add(args):
    incoming = split_tag_values(args.tags)
    if not incoming:
        print("Error: at least one tag is required", file=sys.stderr)
        sys.exit(1)
    items = load_items()
    categories, nodes = load_tag_catalog(items)

    target_parent = None
    target_category = None
    if getattr(args, "category", None) is not None:
        cat_raw = args.category.strip()
        if cat_raw:
            matched_cat = next((c for c in categories if tags_match(c, cat_raw)), None)
            if matched_cat is None:
                print(f"Error: tag category '{args.category}' not found", file=sys.stderr)
                sys.exit(1)
            target_category = matched_cat

    if args.parent is not None:
        parent_raw = args.parent.strip()
        if parent_raw:
            parent_node = next((n for n in nodes if tags_match(n["name"], parent_raw)), None)
            if parent_node is None:
                print(f"Error: parent tag '{args.parent}' not found", file=sys.stderr)
                sys.exit(1)
            target_parent = parent_node["name"]
            target_category = parent_node.get("category")

    added = []
    reparented = []
    for raw in incoming:
        canon = canonical_tag(raw)
        if not canon:
            continue
        existing = next((n for n in nodes if tags_match(n["name"], canon)), None)
        if existing is not None:
            if args.parent is not None:
                if not can_set_parent(existing["name"], target_parent, nodes):
                    print(
                        f"Error: cannot set parent of '{existing['name']}' to '{target_parent}' (cycle or invalid)",
                        file=sys.stderr,
                    )
                    sys.exit(1)
                old_parent = existing.get("parent")
                if (old_parent or "").lower() != (target_parent or "").lower():
                    existing["parent"] = target_parent
                    reparented.append(existing["name"])
            if getattr(args, "category", None) is not None and args.parent is None:
                existing["category"] = target_category
                existing["parent"] = None
        else:
            if target_parent is not None and tags_match(canon, target_parent):
                print(f"Error: tag '{canon}' cannot be its own parent", file=sys.stderr)
                sys.exit(1)
            nodes.append({"name": canon, "category": target_category, "parent": target_parent})
            added.append(canon)

    categories, nodes = normalize_tag_catalog(categories, nodes)
    save_tag_catalog(categories, nodes)
    parts = []
    if added:
        parts.append(f"added=[{', '.join(added)}]")
    if reparented:
        parts.append(f"reparented=[{', '.join(reparented)}]")
    if not parts:
        parts.append("(already existed)")
    parent_note = f" | parent={target_parent}" if target_parent else ""
    cat_note = f" | category={target_category}" if target_category else ""
    print(f"TAGS_UPDATED: {' '.join(parts)}{cat_note}{parent_note} | total={len(nodes)}")


def write_tags_rename(args):
    old_raw = args.old.strip()
    new_raw = args.new.strip()
    if not old_raw or not new_raw:
        print("Error: both old and new tag names must be non-empty", file=sys.stderr)
        sys.exit(1)

    items = load_items()
    categories, nodes = load_tag_catalog(items)

    existing_target = next(
        (n for n in nodes if not tags_match(n["name"], old_raw) and tags_match(n["name"], new_raw)),
        None,
    )
    target = existing_target["name"] if existing_target else (canonical_tag(new_raw) or new_raw)
    merging = existing_target is not None

    new_nodes = []
    found_old = False
    for node in nodes:
        if tags_match(node["name"], old_raw):
            found_old = True
            if merging:
                continue
            updated_node = dict(node)
            updated_node["name"] = target
            if updated_node.get("parent") and tags_match(updated_node["parent"], target):
                updated_node["parent"] = None
            new_nodes.append(updated_node)
        else:
            updated_node = dict(node)
            if updated_node.get("parent") and tags_match(updated_node["parent"], old_raw):
                updated_node["parent"] = target
            new_nodes.append(updated_node)

    if not found_old and not merging:
        new_nodes.append({"name": target, "category": None, "parent": None})

    categories, new_nodes = normalize_tag_catalog(categories, new_nodes)

    updated_items = 0
    for item in items:
        current = get_item_tags(item)
        if any(tags_match(t, old_raw) for t in current):
            replaced = [target if tags_match(t, old_raw) else t for t in current]
            set_item_tags(item, replaced)
            updated_items += 1

    if updated_items > 0:
        save_items(items)
    save_tag_catalog(categories, new_nodes)
    print(f"RENAMED: '{old_raw}' -> '{target}' (updated {updated_items} item(s))")


def write_tags_delete(args):
    targets = split_tag_values(args.tags)
    if not targets:
        print("Error: at least one tag is required", file=sys.stderr)
        sys.exit(1)

    items = load_items()
    categories, nodes = load_tag_catalog(items)

    to_delete: list[str] = []
    seen_del: set[str] = set()
    for target in targets:
        for member in expanded_family(target, nodes):
            key = canonical_tag(member).lower()
            if key and key not in seen_del:
                seen_del.add(key)
                to_delete.append(member)

    new_nodes = [
        n for n in nodes if not any(tags_match(n["name"], target) for target in to_delete)
    ]
    categories, new_nodes = normalize_tag_catalog(categories, new_nodes)

    updated_items = 0
    for item in items:
        current = get_item_tags(item)
        filtered = [t for t in current if not any(tags_match(t, target) for target in to_delete)]
        if filtered != current:
            set_item_tags(item, filtered)
            updated_items += 1

    if updated_items > 0:
        save_items(items)
    save_tag_catalog(categories, new_nodes)
    deleted_desc = ", ".join(to_delete) if to_delete else ", ".join(targets)
    print(f"DELETED: {deleted_desc} (updated {updated_items} item(s))")


def cmd_categories_list(args):
    items = load_items()
    categories, nodes = load_tag_catalog(items)
    print(f"Tag categories ({len(categories)}):")
    for cat in categories:
        count = sum(1 for n in nodes if (n.get("category") or "").lower() == cat.lower())
        en_hint = ZH_TO_EN_TAGS.get(cat)
        label = f"{cat} ({en_hint})" if en_hint else cat
        print(f"- {label}: {count} tag(s)")


def write_categories_add(args):
    items = load_items()
    categories, nodes = load_tag_catalog(items)
    added = []
    for raw in args.categories:
        canon = canonical_tag(raw)
        if canon and not any(tags_match(c, canon) for c in categories):
            categories.append(canon)
            added.append(canon)
    categories, nodes = normalize_tag_catalog(categories, nodes)
    save_tag_catalog(categories, nodes)
    print(f"CATEGORIES_ADDED: [{', '.join(added)}] | total={len(categories)}")


def write_categories_rename(args):
    old_raw = args.old.strip()
    new_raw = canonical_tag(args.new.strip())
    if not old_raw or not new_raw:
        print("Error: both old and new category names must be non-empty", file=sys.stderr)
        sys.exit(1)
    items = load_items()
    categories, nodes = load_tag_catalog(items)
    existing_target = next((c for c in categories if not tags_match(c, old_raw) and tags_match(c, new_raw)), None)
    target = existing_target or new_raw
    updated_cats = []
    for c in categories:
        if tags_match(c, old_raw):
            if not existing_target:
                updated_cats.append(target)
        else:
            updated_cats.append(c)
    for n in nodes:
        if n.get("category") and tags_match(n["category"], old_raw):
            n["category"] = target
    categories, nodes = normalize_tag_catalog(updated_cats, nodes)
    save_tag_catalog(categories, nodes)
    print(f"CATEGORY_RENAMED: '{old_raw}' -> '{target}'")


def write_categories_delete(args):
    targets = split_tag_values(args.categories)
    items = load_items()
    categories, nodes = load_tag_catalog(items)
    updated_cats = [c for c in categories if not any(tags_match(c, t) for t in targets)]
    for n in nodes:
        if n.get("category") and any(tags_match(n["category"], t) for t in targets):
            n["category"] = None
    categories, nodes = normalize_tag_catalog(updated_cats, nodes)
    save_tag_catalog(categories, nodes)
    print(f"CATEGORIES_DELETED: {', '.join(targets)} (tags moved to Uncategorized)")


def main():
    parser = argparse.ArgumentParser(description="Shelf (作品库) Library Management Helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="Search or list items in library.json")
    p_list.add_argument("--query", "-q", default="", help="Keyword to filter title/titleEN/tags/notes")
    p_list.add_argument("--category", "-c", choices=VALID_CATEGORIES, help="Filter by category")
    p_list.add_argument("--status", "-s", choices=VALID_STATUSES, help="Filter by status")
    p_list.add_argument("--tag", "-t", default=None, help="Filter by tag (includes nested child tags)")
    p_list.add_argument("--untagged", action="store_true", help="Filter items with no tags")
    p_list.add_argument("--limit", type=int, default=30)
    p_list.set_defaults(func=cmd_list)

    p_cov = sub.add_parser("search-cover", help="Search vertical poster URLs from Steam/Bangumi/Apple")
    p_cov.add_argument("query", help="Work title to search")
    p_cov.add_argument("--category", "-c", choices=VALID_CATEGORIES, default=None)
    p_cov.set_defaults(func=cmd_search_cover)

    p_up = sub.add_parser("upsert", help="Safely add or update an item in Shelf library.json")
    p_up.add_argument("--id", help="Optional existing UUID to update")
    p_up.add_argument("--title", required=True, help="Official Simplified Chinese title (or original title if no official ZH translation)")
    p_up.add_argument("--title-en", default=None, help="Official English title (pass '' if no official EN translation)")
    p_up.add_argument("--category", "-c", required=True, choices=VALID_CATEGORIES)
    p_up.add_argument("--status", "-s", required=True, choices=VALID_STATUSES)
    p_up.add_argument("--tags", default=None, help="Comma-separated unified tags (e.g. 'Steam,解谜')")
    p_up.add_argument("--add-tag", action="append", default=None, help="Add tag(s) while preserving existing tags")
    p_up.add_argument("--remove-tag", action="append", default=None, help="Remove tag(s) from existing tags")
    p_up.add_argument("--subtag", default=None, help="Legacy single-tag option (prefer --tags)")
    p_up.add_argument("--rating", type=int, default=None, help="0 (unrated) to 5")
    p_up.add_argument("--notes", default=None, help="User notes or author credit")
    p_up.add_argument("--cover-url", default=None, help="Remote image URL to download as 2:3 cover")
    p_up.add_argument("--cover-file", default=None, help="Local image file path to copy as cover")
    p_up.add_argument("--open", action="store_true", help="Open Shelf after saving even if it was closed")
    p_up.set_defaults(func=cmd_upsert)

    p_tags = sub.add_parser("tags", help="List, add, rename, or delete managed tags")
    tags_sub = p_tags.add_subparsers(dest="tags_cmd", required=True)

    p_t_list = tags_sub.add_parser("list", help="List all managed tags and item counts")
    p_t_list.set_defaults(func=cmd_tags_list)

    p_t_add = tags_sub.add_parser("add", help="Add new tag(s) to tags.json (or assign --category / --parent)")
    p_t_add.add_argument("tags", nargs="+", help="Tag name(s) to add")
    p_t_add.add_argument("--category", "-c", default=None, help="Optional tag category to assign (pass '' for uncategorized)")
    p_t_add.add_argument("--parent", "-p", default=None, help="Optional parent tag to nest under (pass '' for top-level)")
    p_t_add.add_argument("--open", action="store_true", help="Open Shelf after saving")
    p_t_add.set_defaults(func=lambda a: run_with_library_lock(a.open, lambda: write_tags_add(a)))

    p_t_rename = tags_sub.add_parser("rename", help="Rename a tag across tags.json and all items")
    p_t_rename.add_argument("old", help="Existing tag name")
    p_t_rename.add_argument("new", help="New tag name")
    p_t_rename.add_argument("--open", action="store_true", help="Open Shelf after saving")
    p_t_rename.set_defaults(func=lambda a: run_with_library_lock(a.open, lambda: write_tags_rename(a)))

    p_t_del = tags_sub.add_parser("delete", help="Delete tag(s) from tags.json and remove from all items")
    p_t_del.add_argument("tags", nargs="+", help="Tag name(s) to delete")
    p_t_del.add_argument("--open", action="store_true", help="Open Shelf after saving")
    p_t_del.set_defaults(func=lambda a: run_with_library_lock(a.open, lambda: write_tags_delete(a)))

    p_t_cat = tags_sub.add_parser("categories", help="List, add, rename, or delete tag categories")
    cat_sub = p_t_cat.add_subparsers(dest="cat_cmd", required=True)
    p_c_list = cat_sub.add_parser("list", help="List all tag categories")
    p_c_list.set_defaults(func=cmd_categories_list)
    p_c_add = cat_sub.add_parser("add", help="Add new tag category(ies)")
    p_c_add.add_argument("categories", nargs="+", help="Category name(s)")
    p_c_add.add_argument("--open", action="store_true", help="Open Shelf after saving")
    p_c_add.set_defaults(func=lambda a: run_with_library_lock(a.open, lambda: write_categories_add(a)))
    p_c_ren = cat_sub.add_parser("rename", help="Rename a tag category")
    p_c_ren.add_argument("old", help="Existing category name")
    p_c_ren.add_argument("new", help="New category name")
    p_c_ren.add_argument("--open", action="store_true", help="Open Shelf after saving")
    p_c_ren.set_defaults(func=lambda a: run_with_library_lock(a.open, lambda: write_categories_rename(a)))
    p_c_del = cat_sub.add_parser("delete", help="Delete tag category(ies) (tags move to Uncategorized)")
    p_c_del.add_argument("categories", nargs="+", help="Category name(s)")
    p_c_del.add_argument("--open", action="store_true", help="Open Shelf after saving")
    p_c_del.set_defaults(func=lambda a: run_with_library_lock(a.open, lambda: write_categories_delete(a)))

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
