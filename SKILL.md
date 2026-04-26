---
name: ghost-mode
description: Browser-style incognito mode for your OpenClaw agent. Activate to pause all memory writes — when you deactivate, every trace of the session is securely scrubbed from logs, memory files, session transcripts, and search indexes. Like closing an incognito window: nothing persists. Any files or local outputs you independently create during the session remain untouched. Use when user says "ghost on", "ghost off", "incognito", "private mode", "privacy mode", or wants a conversation that leaves no persistent trace in agent memory.
---

# Ghost Mode

**Incognito mode for your OpenClaw agent — like a browser's private window, but for your AI.**

Activate, and the agent stops writing to memory. Deactivate, and every trace of the session — logs, memory files, session transcripts, search index entries — is securely scrubbed. Like closing an incognito browser window: the activity never happened, as far as the agent's memory is concerned.

**What stays:** Any files or local outputs you independently create during the session (code, documents, images, etc.) are not touched. Ghost Mode only impacts the agent's memory and session history — nothing else.

User-controlled, explicit, and auditable. No silent hooks, no background daemons, no automatic interception.

## When to Use Ghost Mode

- **Experimental work** — Trying an approach you don't want the agent to learn from or reference later. Test something wild, then close the incognito window.
- **Sensitive conversations** — Discussing personal matters, credentials, or anything you don't want persisting in the agent's long-term memory.
- **Exploring bad ideas** — Prototyping something you might discard. No point polluting the agent's context with abandoned directions.
- **One-off tasks** — Quick operations where the agent doesn't need to remember what it did.
- **Debugging the agent itself** — Testing agent behavior without creating a memory trail that could influence future sessions.
- **Shared environments** — Using an agent on a machine others can access, and you want to keep certain sessions private.
- **Resetting context pressure** — The agent accumulates context over time. Ghost Mode lets you have a "clean room" conversation without adding to that weight.

## Example Sessions

### Example 1: Quick experiment

```
You: ghost on
Agent: Ghost mode ON. This session will not be recorded. Memory writes are suppressed until you say "ghost off".

You: Let me try refactoring the auth module with a completely different pattern...
Agent: [works on refactoring, creates files, runs tests]

You: Actually, that didn't work. Let me scrap it.
Agent: [deletes the experimental code]

You: ghost off
Agent: Ghost mode OFF. Session data has been scrubbed. The agent has no memory of this conversation.
```

Result: The agent's memory is untouched. The experimental refactoring was never recorded. Any files you created or deleted during the session remain as-is.

### Example 2: Sensitive discussion

```
You: ghost on
Agent: Ghost mode ON. This session will not be recorded.

You: I need to share some confidential API keys with you so you can test the integration.
Agent: [helps with integration, reads keys from environment, runs tests]

You: Thanks, that's done. ghost off
Agent: Ghost mode OFF. Session scrubbed. No record of keys or this conversation remains in my memory.
```

Result: Credentials were used during the session but never written to daily logs, memory files, or session archives. The agent won't reference them later.

### Example 3: Exploring a bad direction

```
You: ghost on
Agent: Ghost mode ON.

You: What if we rewrite the entire backend in Rust?
Agent: [explores the idea, generates code, benchmarks...]

You: Okay, this is clearly not worth it right now. ghost off
Agent: Ghost mode OFF. Scrubbed. The Rust exploration never happened, as far as my memory is concerned.
```

Result: The agent won't later suggest Rust or reference the abandoned exploration in future sessions.

### Example 4: Checking status

```
You: ghost status
Agent: Ghost mode: ACTIVE
         Session: ghost-1777145449
         Activated: 2026-04-25T19:30:49Z
         Registry shows 1 session in active state.
```

---

## ⚠️ DATA LOSS WARNING — READ BEFORE INSTALLING

**This skill permanently deletes data by design.**

When you run `ghost off` or `force-cleanup-all`, the skill:
- **Scrubbs** entries from your daily logs, semantic memory, and episodic memory files
- **Archives then shreds** session transcripts and checkpoint files using `shred -u` (secure overwrite, then remove)
- **Removes** entries from the OpenClaw memory search index

**This is irreversible.** Deleted files are not recoverable — not from trash, not from backup, not from any undo mechanism. This is the entire point of the skill, not a side effect.

**The following scenarios can cause unintended data loss:**
- **Bugs or errors** in the scrubbing logic may remove more content than intended
- **Misuse** — running `ghost off` in the wrong session or at the wrong time
- **Environment conflicts** — if your workspace layout differs from the expected OpenClaw structure, scrubbing may target the wrong files or miss files it should clean
- **Partial failures** — if the pipeline crashes mid-run, some files may be scrubbed while others remain, leaving your memory in an inconsistent state
- **Stale sessions** — if a ghost session spans multiple days, scrubbing will affect all entries in that time window across all files, including content from other sessions

**By installing this skill, you acknowledge and accept these risks.**

**Recommended: enable daily OpenClaw workspace backups.** A `tar` or `rsync` backup of `~/.openclaw/workspace/` and `~/.openclaw/data/` run daily ensures you can recover from unintended data loss. Example:

```bash
# Add to crontab for daily 2 AM backup
0 2 * * * tar -czf ~/openclaw-backup-$(date +\%F).tar.gz ~/.openclaw/workspace/ ~/.openclaw/data/
```

---

## How It Works

1. **`ghost on`** — writes a `.ghost-mode` flag file and registers the session in a local JSON registry
2. **Agent reads the flag** — on session start, checks for `.ghost-mode`. If present, suppresses all writes to memory files, daily logs, semantic/episodic files, and MEMORY.md
3. **`ghost off`** — removes the flag, then runs a 5-stage cleanup pipeline:
   - **Archive** → moves session JSONL and checkpoint files to a temporary staging directory
   - **Scrub** → removes ghost-window entries from daily logs, semantic files, episodic files, and MEMORY.md
   - **Index cleanup** → removes matching entries from the OpenClaw memory index (SQLite)
   - **Verify** → 7-layer check confirms no traces remain
   - **Shred** → secure overwrite + delete of all staged files (`shred -u`, falls back to `rm` with warning)

Each stage is idempotent — re-running is safe and produces the same result.

## Quick Start

```bash
# Activate (the agent will also do this when you say "ghost on")
./scripts/ghost_mode.sh on --session-key <key>

# Deactivate and scrub
./scripts/ghost_mode.sh off

# Check status
./scripts/ghost_mode.sh status

# Force cleanup of stale sessions older than 24 hours
./scripts/ghost_mode.sh force-cleanup-all
```

## What This Skill Touches

| Path | Read | Write | Delete | When |
|------|------|-------|--------|------|
| `memory/.ghost-mode` | ✓ | ✓ | ✓ | Flag lifecycle |
| `memory/.ghost-sessions.json` | ✓ | ✓ | — | Registry state machine |
| `memory/YYYY-MM-DD.md` | ✓ | ✓* | — | Scrub ghost-window entries |
| `memory/semantic/*.md` | ✓ | ✓* | — | Scrub ghost-window entries |
| `memory/episodic/*.md` | ✓ | ✓* | — | Scrub ghost-window entries |
| `MEMORY.md` | ✓ | ✓* | — | Scrub promoted ghost entries |
| `~/.openclaw/agents/<agent>/sessions/` | ✓ | — | ✓ | Archive then remove originals |
| `~/.openclaw/ghost-archive/` | ✓ | ✓ | ✓ | Temporary staging, shredded after verify |
| `~/.openclaw/data/memory.db` | ✓ | ✓ | — | Remove index entries for ghost sessions |

\* Writes use atomic rename (`.tmp` → target) — never partial or corrupted files.

All deletions are user-triggered. The skill only acts when you explicitly run `ghost off` or `force-cleanup-all`. No hooks, no daemons, no passive collection.

## What This Skill Does NOT Touch

- **Files you create** — code, documents, images, configs, anything you explicitly write to disk during a ghost session stays exactly where you put it
- **Local outputs** — command output, build artifacts, downloaded files, anything the agent creates as a file output (not a memory entry) is untouched
- OpenClaw gateway logs — outside agent workspace scope
- OS-level process traces — outside agent workspace scope
- Third-party service logs — outside agent workspace scope
- Files outside the OpenClaw workspace — never read or modified
- Network requests — none. Entirely local, no API calls, no cloud services

**The analogy:** Browser incognito mode doesn't delete your downloads. Ghost Mode doesn't delete your files. It only clears the agent's memory of what happened — just like closing a private browsing window clears history but leaves your saved files alone.

## File Layout

```
scripts/
├── ghost_mode.sh           # Main CLI entry point
├── ghost_registry.py       # Session registry + state machine
├── ghost_archive.py        # Session file archival
├── ghost_scrub.py          # Memory file scrubbing
├── ghost_verify.py          # 7-layer verification
└── ghost_index_cleanup.py  # OpenClaw memory index cleanup

references/
└── ARCHITECTURE.md         # Full state machine docs, edge cases, internals
```

## State Machine

```
active → completed → archived → scrubbed → verified → (shredded)
```

Each transition is recorded in the registry with a timestamp. Re-running any stage is safe.

## Post-Install Warning

**The first time the agent detects this skill after installation, it MUST deliver this warning to the user:**

> ⚠️ **Ghost Mode is installed.** This skill permanently deletes data — logs, memory files, session transcripts, and search index entries — using secure deletion (`shred -u`). This is irreversible. Bugs, misuse, or environment conflicts can cause unrecoverable data loss beyond what you intended. By keeping this skill installed, you accept these risks. **Strongly recommended: set up daily backups of `~/.openclaw/workspace/` and `~/.openclaw/data/`.** Run `ghost_mode.sh status` to check the current state at any time.

This warning must be shown **once** after installation. To prevent repeated warnings, after delivering it, create the file `memory/.ghost-mode-warning-shown` in the workspace. On subsequent sessions, check for this file — if it exists, skip the warning.

## AGENTS.md Integration

After installing, add this to your AGENTS.md so the agent respects ghost mode:

```markdown
## Ghost Mode

⚠️ This skill permanently deletes data by design. See the post-install warning for details.

- **"ghost on"** → run `ghost_mode.sh on` immediately
- **"ghost off"** → run `ghost_mode.sh off` immediately
- **"ghost status"** → run `ghost_mode.sh status` and report back

When ghost mode is active (`.ghost-mode` flag exists):
- **ZERO memory writes** — no daily logs, semantic files, episodic files, MEMORY.md, AGENTS.md, USER.md, or SOUL.md updates
- Reading files is still allowed
- Do NOT mention ghost mode in channel messages unless the user asks

### Stale Flag Cleanup
If the `.ghost-mode` flag's `activatedAt` is older than 24 hours:
```bash
ghost_mode.sh force-cleanup-all
```
Remove the flag and proceed normally. Log cleanup to stderr only.
```

## Cron Integration (Optional)

The skill works without cron — `ghost off` runs the full pipeline synchronously. If you want automated cleanup of stale sessions:

```bash
# Archive completed ghost sessions every 15 min (optional)
*/15 * * * * ~/.openclaw/workspace/skills/ghost-mode/scripts/ghost_mode.sh archive-completed

# Verify scrubbed sessions hourly (optional)
0 * * * * ~/.openclaw/workspace/skills/ghost-mode/scripts/ghost_mode.sh verify-pending

# Force cleanup stale sessions daily at 3 AM (optional)
0 3 * * * ~/.openclaw/workspace/skills/ghost-mode/scripts/ghost_mode.sh force-cleanup-all
```

These are **optional** — the primary workflow is manual `ghost on` / `ghost off`.

## Requirements

- **Python 3.8+** — for registry, scrub, verify, and index cleanup scripts
- **`shred`** — standard on Linux. macOS: `brew install coreutils` then use `gshred`
- **OpenClaw workspace** — defaults to `~/.openclaw/workspace/`, configurable via `OPENCLAW_WORKSPACE` env var
- **No external dependencies** — no pip packages, no API keys, no cloud services, no network calls

## Security Model

**Intentionally destructive.** Ghost mode exists to remove data. This is the core purpose, not a side effect.

| Property | Detail |
|----------|--------|
| Deletion method | `shred -u` (secure overwrite, then remove). Falls back to `rm` with warning if `shred` unavailable |
| Registry audit trail | Every state transition is timestamped. You can inspect `memory/.ghost-sessions.json` at any time |
| 7-layer verification | Confirms: flag removed, registry correct, session files gone, checkpoints gone, daily logs clean, semantic files clean, index clean |
| Atomic writes | All file modifications use write-to-`.tmp` then rename — no partial/corrupted state |
| User-triggered only | No automatic hooks. No passive collection. No daemons. Acts only when you run `ghost on`, `ghost off`, or `force-cleanup-all` |
| Local only | No network calls. No API keys. No cloud services. Everything runs on your machine |

**What's out of scope:** Gateway logs, OS process traces, third-party service logs. Ghost mode cleans what the agent controls — your workspace.

## Limitations

- The agent must read the `.ghost-mode` flag at session start. If you activate ghost mode mid-session, the agent won't suppress writes until the next session.
- The OpenClaw gateway logs requests independently. Ghost mode cannot remove gateway logs.
- If the agent crashes before `ghost off`, the flag persists. The next session will detect it. Run `force-cleanup-all` to clean up sessions stale for >24 hours.

## Disclaimer

This skill is provided **as-is, with no warranties, express or implied.** There is no assurance of fitness for any particular purpose, no guarantee of data safety, and no support commitment.

By installing or using this skill, you accept full responsibility for any outcomes. You use this skill entirely at your own risk. The Author is not liable in any way for any losses, damages, or consequences — direct, indirect, incidental, or otherwise — that result from using this skill. This includes, but is not limited to, data loss, corrupted files, lost sessions, or any other damage arising from the use or inability to use this skill.

You are running a tool whose stated purpose is to permanently delete data. Use it carefully. Back up your workspace.

## License

MIT