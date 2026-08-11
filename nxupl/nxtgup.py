#!/usr/bin/env python3
"""
telegram.py — Upload a file to Telegram using the *user* API
(MTProto, via Telethon). Supports files up to ~2GB (regular accounts)
or ~4GB (Telegram Premium), and interactively lets you attach a custom
thumbnail.

First run is interactive: it will ask for your phone number, the login
code Telegram sends you, and your 2FA password if you have one set.
After that, a session file is saved and reused — no more prompts for login.

Usage:
    telegram.py <file> [--caption TEXT] [--thumbnail PATH] [--no-thumbnail]

Reads config from environment variables (set by nxupl from
~/.config/nxupl/nxupl.conf):
    TELEGRAM_API_ID        (int, from https://my.telegram.org)
    TELEGRAM_API_HASH      (from https://my.telegram.org)
    TELEGRAM_USER_CHAT     Target chat: "me" (Saved Messages), a
                            @username, or a numeric chat/user ID.
    TELEGRAM_SESSION_NAME  Optional session file name (default: nxupl_session)
"""
import argparse
import os
import sys
from pathlib import Path

try:
    from telethon import TelegramClient
    from telethon.errors import SessionPasswordNeededError
except ImportError:
    print("[-] Telethon is not installed. Install it with:")
    print("    pip install telethon   (or run ./setup.sh)")
    sys.exit(1)

# Telegram's own thumbnail constraints (it will silently ignore/reject
# thumbnails outside these bounds).
THUMB_MAX_BYTES = 200 * 1024   # 200 KB
THUMB_MAX_DIM = 320            # 320 x 320 px
THUMB_VALID_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def env_or_die(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        print(f"[-] Missing required config: {name}")
        print(f"    Set it in ~/.config/nxupl/nxupl.conf")
        sys.exit(1)
    return val


def progress_bar(current: int, total: int):
    pct = current / total * 100 if total else 0
    bar_len = 30
    filled = int(bar_len * current / total) if total else 0
    bar = "#" * filled + "-" * (bar_len - filled)
    mb_cur = current / (1024 * 1024)
    mb_tot = total / (1024 * 1024)
    sys.stdout.write(f"\r[{bar}] {pct:5.1f}%  ({mb_cur:.1f}/{mb_tot:.1f} MB)")
    sys.stdout.flush()
    if current >= total:
        sys.stdout.write("\n")


def validate_thumbnail(path: Path) -> bool:
    """Best-effort check against Telegram's thumbnail rules. Warns but
    doesn't block — Telegram will just reject it server-side if invalid."""
    if not path.is_file():
        print(f"[-] Thumbnail not found: {path}")
        return False
    if path.suffix.lower() not in THUMB_VALID_EXTS:
        print(f"[!] Warning: unusual thumbnail extension '{path.suffix}'. "
              f"JPEG is safest.")
    size = path.stat().st_size
    if size > THUMB_MAX_BYTES:
        print(f"[!] Warning: thumbnail is {size / 1024:.0f}KB, "
              f"Telegram's limit is {THUMB_MAX_BYTES // 1024}KB. "
              f"It may be rejected or auto-resized.")
    try:
        from PIL import Image
        with Image.open(path) as img:
            w, h = img.size
            if w > THUMB_MAX_DIM or h > THUMB_MAX_DIM:
                print(f"[!] Warning: thumbnail is {w}x{h}px, "
                      f"Telegram's limit is {THUMB_MAX_DIM}x{THUMB_MAX_DIM}px. "
                      f"It may be rejected or auto-resized.")
    except ImportError:
        pass  # Pillow not installed — skip dimension check, not fatal
    except Exception as e:
        print(f"[!] Warning: could not read thumbnail image: {e}")
    return True


def prompt_for_thumbnail():
    """Interactively ask the user whether to attach a thumbnail."""
    try:
        answer = input("[?] Attach a custom thumbnail for this upload? [y/N]: ").strip().lower()
    except EOFError:
        return None
    if answer not in ("y", "yes"):
        return None

    while True:
        try:
            raw_path = input("[?] Path to thumbnail image (JPEG, <=200KB, <=320x320, blank to cancel): ").strip()
        except EOFError:
            return None
        if not raw_path:
            print("[*] Skipping thumbnail.")
            return None
        path = Path(os.path.expanduser(raw_path))
        if validate_thumbnail(path):
            return str(path)
        print("[*] Try another path, or leave blank to skip.")


def main():
    parser = argparse.ArgumentParser(description="Upload a file to Telegram via user API (Telethon)")
    parser.add_argument("file", help="Path to the file to upload")
    parser.add_argument("--caption", default=None, help="Optional caption/message for the file")
    parser.add_argument("--thumbnail", default=None, help="Path to a thumbnail image (skips the interactive prompt)")
    parser.add_argument("--no-thumbnail", action="store_true", help="Skip the thumbnail prompt entirely")
    args = parser.parse_args()

    file_path = Path(args.file)
    if not file_path.is_file():
        print(f"[-] File not found: {file_path}")
        sys.exit(1)

    api_id = int(env_or_die("TELEGRAM_API_ID"))
    api_hash = env_or_die("TELEGRAM_API_HASH")
    target_chat = env_or_die("TELEGRAM_USER_CHAT")
    session_name = os.environ.get("TELEGRAM_SESSION_NAME", "nxupl_session").strip() or "nxupl_session"

    # Store the session file alongside the config, not in cwd
    config_dir = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "nxupl"
    config_dir.mkdir(parents=True, exist_ok=True)
    session_path = config_dir / session_name

    size_mb = file_path.stat().st_size / (1024 * 1024)
    print(f"[*] File: {file_path.name} ({size_mb:.1f} MB)")

    # --- Thumbnail selection (interactive unless overridden by flags) ---
    thumb_path = None
    if args.thumbnail:
        thumb = Path(os.path.expanduser(args.thumbnail))
        if validate_thumbnail(thumb):
            thumb_path = str(thumb)
        else:
            print("[-] Provided --thumbnail is invalid, continuing without one.")
    elif args.no_thumbnail:
        pass
    elif sys.stdin.isatty():
        thumb_path = prompt_for_thumbnail()

    if thumb_path:
        print(f"[+] Using thumbnail: {thumb_path}")

    client = TelegramClient(str(session_path), api_id, api_hash)

    async def run():
        await client.connect()
        if not await client.is_user_authorized():
            print("[*] First-time login required.")
            phone = input("    Enter your phone number (with country code, e.g. +15551234567): ").strip()
            await client.send_code_request(phone)
            code = input("    Enter the login code Telegram sent you: ").strip()
            try:
                await client.sign_in(phone=phone, code=code)
            except SessionPasswordNeededError:
                pw = input("    Two-factor password: ").strip()
                await client.sign_in(password=pw)
            print("[+] Login successful. Session saved for future runs.")

        entity = await client.get_entity(target_chat) if target_chat != "me" else "me"

        print(f"[*] Uploading to '{target_chat}'...")
        send_kwargs = dict(
            caption=args.caption,
            progress_callback=progress_bar,
            force_document=True,
        )
        if thumb_path:
            send_kwargs["thumb"] = thumb_path

        await client.send_file(entity, str(file_path), **send_kwargs)
        print(f"[+] Upload complete: {file_path.name}")

    with client:
        client.loop.run_until_complete(run())


if __name__ == "__main__":
    main()
