#!/usr/bin/env python3
"""Claude Code status line that also hands Claude's usage to AI Usage Meter.

Optional. The app can get Claude's usage live (the "Check Claude usage live"
setting). This script is the way to get it without the app reading any login:
Claude Code pipes session JSON to it on stdin, and for claude.ai Pro and Max
subscribers that JSON includes `rate_limits` (five-hour and seven-day percentages)
after the first response in a session. Documented at
https://code.claude.com/docs/en/statusline

It does two things:
  1. prints a short status line for Claude Code's terminal UI
  2. writes the readings to ~/Library/Application Support/AIUsageMeter/statusline/claude.json

Notes:
  - It only runs inside Claude Code's interactive terminal UI, not in the desktop
    app or IDE extensions.
  - `received_at` is when this script received the figure, not when Anthropic
    produced it. The app labels it that way.
  - It never fails loudly: an error shows a blank status line rather than breaking
    Claude Code.
  - It writes atomically, so the app never reads a half-written file.
  - A missing window stays missing. Claude Code drops a window once it resets,
    and the app treats that as "unknown", never "0% used".
"""

import json
import os
import sys
import tempfile
import time

# Its own subdirectory on purpose: the app watches this path for live updates,
# and must not also see its own SQLite writes (which would loop endlessly).
OUT_DIR = os.path.expanduser("~/Library/Application Support/AIUsageMeter/statusline")
OUT_FILE = os.path.join(OUT_DIR, "claude.json")


def write_reading(data):
    rate_limits = data.get("rate_limits")
    if not isinstance(rate_limits, dict):
        # No readings in this payload (not an eligible plan, or before the first
        # API response). Leave any previous file untouched rather than
        # overwriting a good reading with an empty one.
        return

    payload = {
        "received_at": time.time(),
        "rate_limits": rate_limits,
        "claude_code_version": data.get("version"),
        "session_id": data.get("session_id"),
    }

    os.makedirs(OUT_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix=".statusline-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(payload, fh)
        os.replace(tmp, OUT_FILE)  # atomic
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def mark_invoked(data):
    """Records that Claude Code ran this script, whether or not it sent usage.

    Without this, "never invoked" (e.g. a host that has no status line) and
    "invoked without rate_limits" (e.g. an ineligible plan) are indistinguishable.
    Only a timestamp and whether the field was present are stored.
    """
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "last-invoked.json"), "w") as fh:
        json.dump({
            "invoked_at": time.time(),
            "had_rate_limits": isinstance(data.get("rate_limits"), dict),
            "claude_code_version": data.get("version"),
        }, fh)


def pct(window):
    if not isinstance(window, dict):
        return None
    value = window.get("used_percentage")
    return value if isinstance(value, (int, float)) else None


def status_text(data):
    parts = []

    model = (data.get("model") or {}).get("display_name")
    if model:
        parts.append(model)

    rl = data.get("rate_limits") or {}
    five, seven = pct(rl.get("five_hour")), pct(rl.get("seven_day"))
    if five is not None:
        parts.append(f"5h {five:.0f}%")
    if seven is not None:
        parts.append(f"7d {seven:.0f}%")
    if five is None and seven is None:
        parts.append("usage n/a")

    cwd = data.get("workspace", {}).get("current_dir") or data.get("cwd")
    if cwd:
        parts.append(os.path.basename(cwd))

    return "  ·  ".join(parts)


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        print("")
        return

    try:
        mark_invoked(data)
    except Exception:
        pass

    try:
        write_reading(data)
    except Exception:
        pass  # never let persistence break the visible status line

    try:
        print(status_text(data))
    except Exception:
        print("")


if __name__ == "__main__":
    main()
