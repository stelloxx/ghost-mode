#!/usr/bin/env python3
"""Ghost Mode Scrubber - Remove ghost session content from memory files.

Generic version: scrubs daily logs, semantic files, and episodic files.
No agent-specific assumptions.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from ghost_registry import WORKSPACE, load_registry

MEMORY_DIR = WORKSPACE / "memory"
SEMANTIC_DIR = MEMORY_DIR / "semantic"
EPISODIC_DIR = MEMORY_DIR / "episodic"
DAILY_LOG_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}")


def parse_iso_timestamp(ts_str):
    """Parse ISO 8601 timestamp to datetime."""
    # Handle various formats
    ts_str = ts_str.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(ts_str)
    except (ValueError, AttributeError):
        return None


def is_in_ghost_window(timestamp_str, ghost_start, ghost_end):
    """Check if a timestamp falls within the ghost window."""
    ts = parse_iso_timestamp(timestamp_str)
    if ts is None:
        return False
    # Make both timezone-aware for comparison
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    start = ghost_start.replace(tzinfo=timezone.utc) if ghost_start.tzinfo is None else ghost_start
    end = ghost_end.replace(tzinfo=timezone.utc) if ghost_end.tzinfo is None else ghost_end
    return start <= ts <= end


def scrub_daily_logs(ghost_start, ghost_end):
    """Remove entries with timestamps in the ghost window from daily logs."""
    scrubbed = 0

    for log_file in MEMORY_DIR.glob("*.md"):
        if not DAILY_LOG_PATTERN.match(log_file.name):
            continue

        with open(log_file) as f:
            lines = f.readlines()

        new_lines = []
        skip_block = False
        block_timestamp = None

        for line in lines:
            # Check for timestamp markers in log entries
            ts_match = re.search(r"(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})", line)
            if ts_match:
                ts_str = ts_match.group(1)
                if is_in_ghost_window(ts_str, ghost_start, ghost_end):
                    skip_block = True
                    continue

            # Check for session headers that might indicate ghost content
            session_match = re.search(r"Session:\s*\d{4}-\d{2}-\d{2}", line)
            if session_match:
                # Extract date from session header
                date_str = re.search(r"(\d{4}-\d{2}-\d{2})", line)
                if date_str:
                    file_date = date_str.group(1)
                    # Check if this date falls in ghost window
                    file_dt = datetime.strptime(file_date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
                    if ghost_start <= file_dt <= ghost_end:
                        skip_block = True
                        continue

            if skip_block and line.strip() == "":
                skip_block = False
                continue

            if not skip_block:
                new_lines.append(line)

        if len(new_lines) != len(lines):
            # Atomic write
            tmp = log_file.with_suffix(".tmp")
            with open(tmp, "w") as f:
                f.writelines(new_lines)
            tmp.rename(log_file)
            scrubbed += 1
            print(f"Scrubbed: {log_file.name} ({len(lines) - len(new_lines)} lines removed)", file=sys.stderr)

    return scrubbed


def scrub_file_by_mtime(file_path, ghost_start, ghost_end):
    """Scrub entries from a memory file based on mtime and content timestamps."""
    mtime = datetime.fromtimestamp(file_path.stat().st_mtime, tz=timezone.utc)

    # Only scrub if the file was modified during the ghost window
    if not (ghost_start <= mtime <= ghost_end):
        return False

    with open(file_path) as f:
        content = f.read()

    # Check for ghost session ID references in content
    # This handles promoted entries with source citations
    original_len = len(content)

    # Remove lines containing ghost-window timestamps
    lines = content.split("\n")
    new_lines = []
    for line in lines:
        ts_matches = re.findall(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}", line)
        in_window = any(is_in_ghost_window(ts, ghost_start, ghost_end) for ts in ts_matches)
        if not in_window:
            new_lines.append(line)

    new_content = "\n".join(new_lines)

    if len(new_content) < original_len:
        # Atomic write
        tmp = file_path.with_suffix(".tmp")
        with open(tmp, "w") as f:
            f.write(new_content)
        tmp.rename(file_path)
        print(f"Scrubbed: {file_path.name}", file=sys.stderr)
        return True

    return False


def scrub_semantic_files(ghost_start, ghost_end):
    """Scrub ghost-window entries from semantic memory files."""
    scrubbed = 0
    if not SEMANTIC_DIR.exists():
        return scrubbed

    for f in SEMANTIC_DIR.glob("*.md"):
        if scrub_file_by_mtime(f, ghost_start, ghost_end):
            scrubbed += 1

    return scrubbed


def scrub_episodic_files(ghost_start, ghost_end):
    """Scrub ghost-window entries from episodic memory files."""
    scrubbed = 0
    if not EPISODIC_DIR.exists():
        return scrubbed

    for f in EPISODIC_DIR.glob("*.md"):
        if scrub_file_by_mtime(f, ghost_start, ghost_end):
            scrubbed += 1

    return scrubbed


def scrub_memory_md(ghost_start, ghost_end, session_ids):
    """Scrub promoted entries from MEMORY.md that reference ghost sessions."""
    memory_file = MEMORY_DIR / "MEMORY.md"
    if not memory_file.exists():
        return False

    with open(memory_file) as f:
        content = f.read()

    original_len = len(content)
    lines = content.split("\n")
    new_lines = []

    i = 0
    while i < len(lines):
        line = lines[i]
        # Check for promotion markers with ghost session IDs or ghost-window timestamps
        if any(sid in line for sid in session_ids):
            # Skip this line and any following lines that are part of the same block
            i += 1
            continue

        # Check for ghost-window timestamps in promotion markers
        ts_matches = re.findall(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}", line)
        if ts_matches:
            in_window = any(is_in_ghost_window(ts, ghost_start, ghost_end) for ts in ts_matches)
            if in_window:
                i += 1
                continue

        new_lines.append(line)
        i += 1

    new_content = "\n".join(new_lines)

    if len(new_content) < original_len:
        tmp = memory_file.with_suffix(".tmp")
        with open(tmp, "w") as f:
            f.write(new_content)
        tmp.rename(memory_file)
        print(f"Scrubbed: MEMORY.md ({original_len - len(new_content)} chars removed)", file=sys.stderr)
        return True

    return False


def scrub_session(session_id):
    """Run full scrub pipeline for a session."""
    registry = load_registry()
    entry = registry["sessions"].get(session_id)
    if not entry:
        print(f"Session {session_id} not found in registry", file=sys.stderr)
        return False

    if entry["status"] not in ("archived",):
        print(f"Session {session_id} status is {entry['status']}, expected 'archived'", file=sys.stderr)
        return False

    ghost_start = parse_iso_timestamp(entry["activatedAt"])
    ghost_end = datetime.now(timezone.utc)

    if ghost_start is None:
        print(f"Could not parse activatedAt: {entry['activatedAt']}", file=sys.stderr)
        return False

    print(f"Scrubbing session {session_id} (window: {ghost_start} to {ghost_end})", file=sys.stderr)

    daily = scrub_daily_logs(ghost_start, ghost_end)
    semantic = scrub_semantic_files(ghost_start, ghost_end)
    episodic = scrub_episodic_files(ghost_start, ghost_end)
    memory_md = scrub_memory_md(ghost_start, ghost_end, [session_id])

    from ghost_registry import update_status
    update_status(session_id, "scrubbed")

    print(f"Scrub complete: {daily} daily logs, {semantic} semantic files, {episodic} episodic files, MEMORY.md={memory_md}", file=sys.stderr)
    return True


def scrub_all_archived():
    """Scrub all sessions with status 'archived'."""
    from ghost_registry import list_sessions

    archived = list_sessions(status="archived")
    scrubbed = 0
    for session in archived:
        if scrub_session(session["sessionId"]):
            scrubbed += 1

    print(f"Scrubbed {scrubbed} sessions", file=sys.stderr)
    return scrubbed


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Ghost Mode Scrubber")
    sub = parser.add_subparsers(dest="command")

    session_p = sub.add_parser("session", help="Scrub a specific session")
    session_p.add_argument("session_id")

    all_p = sub.add_parser("archived", help="Scrub all archived sessions")

    args = parser.parse_args()

    # Add scripts dir to path for imports
    sys.path.insert(0, str(Path(__file__).parent))

    if args.command == "session":
        scrub_session(args.session_id)
    elif args.command == "archived":
        scrub_all_archived()
    else:
        parser.print_help()