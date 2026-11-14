#!/usr/bin/env python3
"""
Helper CLI for reading and updating Shelf (作品库) local data safely.
Data path: ~/Library/Application Support/Shelf/library.json
Covers dir: ~/Library/Application Support/Shelf/Covers/
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
from datetime import datetime, timezone

BASE_DIR = os.path.expanduser("~/Library/Application Support/Shelf")
LIB_PATH = os.path.join(BASE_DIR, "library.json")
COVERS_DIR = os.path.join(BASE_DIR, "Covers")

VALID_CATEGORIES = ("game", "novel", "video")
VALID_STATUSES = ("active", "completed", "unfinished", "backlog")


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
    """Quits Shelf.app if running so its applicationWillTerminate flush completes BEFORE we edit library.json."""
    if not is_shelf_running():
        return False
    subprocess.run(["pkill", "-x", "Shelf"], capture_output=True)
    for _ in range(15):
        time.sleep(0.1)
        if not is_shelf_running():
            break
    time.sleep(0.2)
    return True


def relaunch_shelf_if_possible():
    app_path = find_shelf_app_bundle()
    if app_path:
        subprocess.run(["open", app_path], check=False)


def load_items() -> list[dict]:
    os.makedirs(COVERS_DIR, exist_ok=True)
    if not os.path.exists(LIB_PATH):
        return []
    with open(LIB_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def save_items(items: list[dict]):
    os.makedirs(BASE_DIR, exist_ok=True)
    tmp_path = LIB_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp_path, LIB_PATH)


def save_cover_image(source_url: str | None, source_file: str | None) -> str:
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
        "User-Agent: ShelfMacApp/1.1 (macOS)",
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
    q = (args.query or "").strip().lower()
    matched = []
    for item in items:
        if args.category and item.get("category") != args.category:
            continue
        if args.status and item.get("status") != args.status:
            continue
        if q:
            hay = " | ".join(
                [
                    item.get("title", ""),
                    item.get("titleEN", ""),
                    item.get("subtag", ""),
                    item.get("notes", ""),
                ]
            ).lower()
            if q not in hay:
                continue
        matched.append(item)

    print(f"Matched {len(matched)} / {len(items)} total items:")
    for x in matched[: args.limit]:
        has_cover = "yes" if x.get("coverFileName") else "NO"
        print(
            f"- id={x['id']} | {x['category']} | {x['status']} | "
            f"ZH={x.get('title','')} | EN={x.get('titleEN','')} | "
            f"subtag={x.get('subtag','')} | rating={x.get('rating',0)} | cover={has_cover}"
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


def cmd_upsert(args):
    was_running = quit_shelf_safely()
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
    if args.cover_url or args.cover_file:
        new_cover_name = save_cover_image(args.cover_url, args.cover_file)

    if target is not None:
        action = "UPDATED"
        target["title"] = title_zh
        if args.title_en is not None:
            target["titleEN"] = title_en
        target["category"] = args.category
        target["status"] = args.status
        if args.subtag is not None:
            target["subtag"] = args.subtag.strip()
        if args.rating is not None:
            target["rating"] = max(0, min(5, args.rating))
        if args.notes is not None:
            target["notes"] = args.notes
        if new_cover_name:
            old_cover = target.get("coverFileName")
            if old_cover and old_cover != new_cover_name:
                old_path = os.path.join(COVERS_DIR, old_cover)
                if os.path.exists(old_path):
                    os.remove(old_path)
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
            "subtag": (args.subtag or "").strip(),
            "rating": max(0, min(5, args.rating if args.rating is not None else 0)),
            "notes": args.notes if args.notes is not None else "",
            "coverFileName": new_cover_name,
            "paletteSeed": random.randint(0, 999),
            "createdAt": now_iso,
            "updatedAt": now_iso,
            "isSample": False,
        }
        items.insert(0, entry)

    save_items(items)

    if was_running or args.open:
        relaunch_shelf_if_possible()

    cover_fn = entry.get("coverFileName")
    cover_abs = os.path.join(COVERS_DIR, cover_fn) if cover_fn else None
    print(f"{action}: id={entry['id']} | {entry['category']} | {entry['status']} | ZH={entry['title']} | EN={entry.get('titleEN','')}")
    if cover_abs:
        print(f"COVER_PATH: {cover_abs}")
    else:
        print("COVER_PATH: NONE (Warning: no cover image attached yet!)")


def main():
    parser = argparse.ArgumentParser(description="Shelf (作品库) Library Management Helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="Search or list items in library.json")
    p_list.add_argument("--query", "-q", default="", help="Keyword to filter title/titleEN/subtag/notes")
    p_list.add_argument("--category", "-c", choices=VALID_CATEGORIES, help="Filter by category")
    p_list.add_argument("--status", "-s", choices=VALID_STATUSES, help="Filter by status")
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
    p_up.add_argument("--subtag", default=None, help="Platform / Genre / Format subtag")
    p_up.add_argument("--rating", type=int, default=None, help="0 (unrated) to 5")
    p_up.add_argument("--notes", default=None, help="User notes or author credit")
    p_up.add_argument("--cover-url", default=None, help="Remote image URL to download as 2:3 cover")
    p_up.add_argument("--cover-file", default=None, help="Local image file path to copy as cover")
    p_up.add_argument("--open", action="store_true", help="Open Shelf.app after saving even if it was closed")
    p_up.set_defaults(func=cmd_upsert)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
