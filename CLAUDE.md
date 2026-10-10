# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Claude Code hooks that mark the terminal (bell, OSC 9;4 tab ring, tab-title mark, dock bounce, Windows taskbar flash) when Claude is waiting for the user, and clear the mark when they respond. No pop-ups, no sound. Only interactive terminal sessions (`CLAUDE_CODE_ENTRYPOINT=cli`); everything else exits immediately. There is no build and no test suite.

## Commands

```sh
./install.sh --dry-run    # print the merged ~/.claude/settings.json, change nothing
./install.sh              # copy scripts to ~/.claude/hooks/ and merge hooks into settings.json
./install.sh --uninstall
sh -n attention.sh        # syntax check

# Drive the hook by hand (uses the repo's attention.conf, state in $TMPDIR/claude-attention-<sid>)
echo '{"session_id":"t"}' | CLAUDE_CODE_ENTRYPOINT=cli sh attention.sh wait done   # -> {"terminalSequence":"\u0007..."}
echo '{"session_id":"t"}' | CLAUDE_CODE_ENTRYPOINT=cli sh attention.sh off
echo '{"session_id":"t","background_tasks":[{"type":"subagent"}],"session_crons":[]}' \
  | CLAUDE_CODE_ENTRYPOINT=cli sh attention.sh wait done                           # prints nothing: "busy"
```

Live sessions run the *installed* copy in `~/.claude/hooks/`, not the repo: re-run `./install.sh` after editing. Script edits take effect on the next event; changes to `attention-hooks.json` need a Claude Code restart. Windows: `install.cmd` / `install.ps1 [-DryRun|-Uninstall]`. The Windows path has not been tested from a Mac (see the checklist at the end of README.md).

## Architecture

- `attention-hooks.json` maps Claude Code events to `attention.sh` subcommands (table in README "How it works"). The installers append these groups to each event in the user's `settings.json`. Hooks must live in user settings: Claude Code only passes `terminalSequence` through for hooks from the user's own settings files, so this can't be a plugin.
- `attention.sh` is the whole runtime, one POSIX `sh` script that must run in macOS `/bin/sh` and Git Bash on Windows (no bashisms; `$RANDOM` has a fallback). Subcommands:
  - `wait <kind>`: writes the per-session state file and prints `{"terminalSequence": ...}` on stdout, which Claude Code writes to the terminal. For `done` it inspects `background_tasks` from the Stop input: agents → record a `busy` wait and signal nothing; only shells/monitors/MCP tasks → detached `late_done_job` signals after `BG_SHELL_MIN`.
  - `arm` (PermissionRequest): records which agent's permission prompt comes next in `$state.req`. **Must print nothing**: PermissionRequest stdout is read as a permission decision.
  - `off [tool|end]`: clears the wait. `off tool` runs after *every* tool call, so its checks (same agent, and for question/plan the same `tool_use_id`) use shell builtins only, before any fork or reading the conf. Keep that path cheap.
- State file `${TMPDIR:-$TEMP}/claude-attention-<session_id>`: line 1 is a random token, then `kind=`, `owner=`, `tool=`. Detached jobs (`title_job`, `nag_job`, `late_done_job`) poll `still_waiting` and exit as soon as the token is gone or replaced; that's how `off` and a newer `wait` stop them.
- Hooks have no controlling terminal. Anything written after the hook returns (title mark, nag bells, late "done") goes straight to the `claude` process's tty, found by walking parents with `ps` (`claude_tty`). It's looked up before the hook exits, since the parent may be gone later.
- macOS "user typed or scrolled in this tab" detection (`used_here`): tty access-time changes, gated on the terminal being frontmost (`lsappinfo`) and a key press or scroll-wheel event in the last second (`osascript` JXA `CGEventSourceSecondsSinceLastEventType`), ignoring reads in the first 7 s after the wait starts.
- Hook input JSON is parsed with the builtin `field` helper (no `jq` at runtime). It only accepts `[A-Za-z0-9_.-]` values.
- `attention.ps1` is only the Windows taskbar flash, launched detached. It finds the window via `GetConsoleProcessList` because the hook's own parent chain is usually gone by then.

## Things to keep in sync

- **Hook ownership marker:** installers recognise "our" hooks by the substring `hooks/attention.sh` in the command. Every command in `attention-hooks.json` must contain it, or upgrades duplicate and uninstall misses.
- **Merge logic exists three times:** the jq and python3 branches in `install.sh` and the PowerShell in `install.ps1`. They strip our hook objects (dropping groups/events only if that empties them) and then append. A change to one needs the same change in all three. The same goes for the "other notifier hooks" warning regex.
- **Settings defaults appear in three places:** the defaults block in `attention.sh`, the commented defaults in `attention.conf` (left commented so they follow upgrades; installers never overwrite an existing user conf), and the Settings table in README.md.
- **Event wiring is documented** in README "How it works". Update it along with `attention-hooks.json`.
- **Line endings** are pinned in `.gitattributes`: `.sh`/`.conf`/`.json` LF, `.ps1`/`.cmd` CRLF. `install.ps1` converts to LF when copying shell files.
