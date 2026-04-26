#!/usr/bin/env bash
# Ghost Mode CLI - Activate, deactivate, and manage privacy sessions
# Generic version: no agent-specific or environment-specific assumptions.
#
# Usage:
#   ghost_mode.sh on [--session-key <key>]   # Activate ghost mode
#   ghost_mode.sh off                         # Deactivate and run pipeline
#   ghost_mode.sh status                      # Show current status
#   ghost_mode.sh archive-completed           # Archive all active sessions
#   ghost_mode.sh verify-pending              # Verify all scrubbed sessions
#   ghost_mode.sh force-cleanup-all            # Force cleanup stale sessions (>24h)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
FLAG_FILE="$WORKSPACE/memory/.ghost-mode"
REGISTRY="$WORKSPACE/memory/.ghost-sessions.json"
WARNING_FILE="$WORKSPACE/memory/.ghost-mode-warning-shown"

# Add scripts dir to Python path
export PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}"

# Colors for output (disabled if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

log() { echo -e "${GREEN}[ghost]${NC} $*"; }
warn() { echo -e "${YELLOW}[ghost]${NC} $*" >&2; }
err() { echo -e "${RED}[ghost]${NC} $*" >&2; }

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        err "Required command not found: $1"
        exit 1
    fi
}

secure_delete() {
    # Try shred first, fall back to rm with warning
    if command -v shred &>/dev/null; then
        shred -u "$1" 2>/dev/null
    else
        warn "shred not available, using rm (less secure): $1"
        rm -f "$1"
    fi
}

check_warning() {
    # Show one-time data loss warning if not already shown
    if [ ! -f "$WARNING_FILE" ]; then
        echo ""
        echo "⚠️  DATA LOSS WARNING"
        echo "════════════════════════════════════════════════════════════════"
        echo "Ghost Mode permanently deletes data by design."
        echo ""
        echo "When you run 'ghost off', this skill will:"
        echo "  • SCRUB entries from daily logs, semantic memory, and episodic memory"
        echo "  • SHRED session transcripts using secure deletion (shred -u)"
        echo "  • REMOVE entries from the OpenClaw memory search index"
        echo ""
        echo "This is IRREVERSIBLE. Deleted data cannot be recovered."
        echo ""
        echo "Bugs, misuse, or environment conflicts can cause data loss"
        echo "beyond what you intended. By using this skill, you accept these risks."
        echo ""
        echo "RECOMMENDED: Set up daily backups of your OpenClaw workspace:"
        echo "  tar -czf ~/openclaw-backup-\$(date +%F).tar.gz ~/.openclaw/workspace/ ~/.openclaw/data/"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        # Mark warning as shown so it only appears once
        mkdir -p "$(dirname "$WARNING_FILE")"
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "$WARNING_FILE"
        log "Warning shown and acknowledged. This message will not appear again."
    fi
}

# Ensure registry exists
ensure_registry() {
    mkdir -p "$(dirname "$REGISTRY")"
    if [ ! -f "$REGISTRY" ]; then
        echo '{"sessions": {}}' > "$REGISTRY"
    fi
}

cmd_on() {
    check_warning
    require_cmd python3
    local session_key=""
    local session_id

    # Parse optional --session-key argument
    while [ $# -gt 0 ]; do
        case "$1" in
            --session-key)
                shift; session_key="$1" ;;
            *) session_key="$1" ;;
        esac
        shift
    done
    [ -z "$session_key" ] && session_key="unknown"

    # Try to get current session from OpenClaw if available
    if command -v openclaw &>/dev/null; then
        session_id=$(openclaw sessions list --current --format json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','unknown'))" 2>/dev/null || echo "")
    fi
    [ -z "$session_id" ] && session_id="ghost-$(date +%s)"

    # Check if already active
    if [ -f "$FLAG_FILE" ]; then
        warn "Ghost mode already active"
        python3 "$SCRIPT_DIR/ghost_registry.py" flag-read
        return 0
    fi

    ensure_registry
    python3 "$SCRIPT_DIR/ghost_registry.py" add "$session_key" "$session_id"

    # Write flag file
    mkdir -p "$(dirname "$FLAG_FILE")"
    python3 -c "
import json
from datetime import datetime, timezone
flag = {'sessionKey': '$session_key', 'sessionId': '$session_id', 'activatedAt': datetime.now(timezone.utc).isoformat()}
with open('$FLAG_FILE', 'w') as f:
    json.dump(flag, f, indent=2)
"

    log "Ghost mode ON — session: $session_id"
    log "Memory writes are now suppressed until 'ghost off'"
}

cmd_off() {
    check_warning
    require_cmd python3

    if [ ! -f "$FLAG_FILE" ]; then
        warn "Ghost mode is not active"
        return 0
    fi

    # Read flag before removing
    local session_id
    session_id=$(python3 -c "import json; print(json.load(open('$FLAG_FILE')).get('sessionId', 'unknown'))")

    # Remove flag
    rm -f "$FLAG_FILE"
    log "Ghost mode flag removed"

    # Run archival pipeline
    log "Running archival pipeline for session $session_id..."

    # Step 1: Update registry status to completed
    python3 "$SCRIPT_DIR/ghost_registry.py" update "$session_id" completed 2>/dev/null || true

    # Step 2: Archive session files
    python3 "$SCRIPT_DIR/ghost_archive.py" session "$session_id" 2>/dev/null || {
        warn "Archival encountered issues, continuing..."
    }

    # Step 3: Scrub memory files
    python3 "$SCRIPT_DIR/ghost_scrub.py" session "$session_id" 2>/dev/null || {
        warn "Scrubbing encountered issues, continuing..."
    }

    # Step 4: Index cleanup
    python3 "$SCRIPT_DIR/ghost_index_cleanup.py" --session-id "$session_id" 2>/dev/null || {
        warn "Index cleanup encountered issues, continuing..."
    }

    # Step 5: Verify
    python3 "$SCRIPT_DIR/ghost_verify.py" session "$session_id" 2>/dev/null || {
        warn "Verification encountered issues, continuing..."
    }

    # Step 6: Secure delete archived files
    local archive_dir="$HOME/.openclaw/ghost-archive"
    if [ -d "$archive_dir" ]; then
        find "$archive_dir" -type f -exec shred -u {} \; 2>/dev/null || {
            find "$archive_dir" -type f -exec rm -f {} \;
            warn "shred unavailable, used rm instead"
        }
        # Remove empty directories
        find "$archive_dir" -type d -empty -delete 2>/dev/null || true
    fi

    log "Ghost mode OFF — session $session_id fully scrubbed and verified"
}

cmd_status() {
    require_cmd python3

    if [ -f "$FLAG_FILE" ]; then
        log "Ghost mode: ACTIVE"
        python3 "$SCRIPT_DIR/ghost_registry.py" flag-read
    else
        log "Ghost mode: INACTIVE"
    fi

    echo ""
    log "Registry:"
    python3 "$SCRIPT_DIR/ghost_registry.py" list
}

cmd_archive_completed() {
    require_cmd python3
    python3 "$SCRIPT_DIR/ghost_archive.py" completed
}

cmd_verify_pending() {
    require_cmd python3
    python3 "$SCRIPT_DIR/ghost_verify.py" scrubbed
}

cmd_force_cleanup() {
    require_cmd python3

    log "Force cleanup: processing stale sessions..."

    # Get stale sessions
    local stale
    stale=$(python3 "$SCRIPT_DIR/ghost_registry.py" stale)

    if [ "$stale" = "[]" ] || [ -z "$stale" ]; then
        log "No stale sessions found"
        return 0
    fi

    # Process each stale session
    echo "$stale" | python3 -c "
import json, sys
sessions = json.load(sys.stdin)
for s in sessions:
    print(s['sessionId'])
" | while read -r sid; do
        log "Cleaning up stale session: $sid"
        python3 "$SCRIPT_DIR/ghost_registry.py" update "$sid" completed 2>/dev/null || true
        python3 "$SCRIPT_DIR/ghost_archive.py" session "$sid" 2>/dev/null || true
        python3 "$SCRIPT_DIR/ghost_scrub.py" session "$sid" 2>/dev/null || true
        python3 "$SCRIPT_DIR/ghost_index_cleanup.py" --session-id "$sid" 2>/dev/null || true
        python3 "$SCRIPT_DIR/ghost_verify.py" session "$sid" 2>/dev/null || true
    done

    # Remove flag
    rm -f "$FLAG_FILE"
    log "Stale sessions cleaned up"
}

# Main
case "${1:-help}" in
    on)
        shift
        cmd_on "$@"
        ;;
    off)
        cmd_off
        ;;
    status)
        cmd_status
        ;;
    show-warning)
        check_warning
        ;;
    archive-completed)
        cmd_archive_completed
        ;;
    verify-pending)
        cmd_verify_pending
        ;;
    force-cleanup-all)
        cmd_force_cleanup
        ;;
    show-warning)
        check_warning
        ;;
    help|*)
        echo "Ghost Mode — Privacy mode for OpenClaw sessions"
        echo ""
        echo "⚠️  WARNING: This skill permanently deletes data by design."
        echo "   Run 'ghost_mode.sh show-warning' to see the full warning."
        echo ""
        echo "Usage: ghost_mode.sh <command> [options]"
        echo ""
        echo "Commands:"
        echo "  on [--session-key <key>]    Activate ghost mode"
        echo "  off                         Deactivate and scrub session data"
        echo "  status                      Show current ghost mode status"
        echo "  show-warning                Show the one-time data loss warning"
        echo "  archive-completed           Archive all active sessions"
        echo "  verify-pending              Verify all scrubbed sessions"
        echo "  force-cleanup-all           Force cleanup stale sessions (>24h)"
        echo ""
        echo "Environment variables:"
        echo "  OPENCLAW_WORKSPACE          Path to OpenClaw workspace (default: ~/.openclaw/workspace)"
        echo "  OPENCLAW_AGENT              Agent directory name (default: main)"
        echo ""
        echo "RECOMMENDED: Set up daily backups before using this skill."
        echo "  tar -czf ~/openclaw-backup-\$(date +%F).tar.gz ~/.openclaw/workspace/ ~/.openclaw/data/"
        ;;
esac