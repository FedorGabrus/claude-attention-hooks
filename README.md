# Claude Code attention hooks

Know when Claude Code is waiting for you, so a long session doesn't need watching.
Works in macOS and Windows terminals.

- **Quiet markers, no pop-ups:** the bell (🔔 on the tab, a dock badge/bounce, a taskbar flash), a mark in the tab title and, where supported, a ring on the tab. They appear at once, make no sound, and clear as soon as you respond.
- **No bounce for a quick answer you watched:** when a turn ends less than 30 s after your prompt, only the title mark (or tab ring) shows at first. The bell follows a minute later if you still haven't responded. Prompts that block Claude (permission, question, plan) always ring at once, and the permission mark names the tool: `🔐 my-app · Bash`.
- **Errors too:** a turn cut short by a rate limit or API error gets a ⚠️ mark instead of looking busy forever.
- **Not while Claude is still busy in the background:** if the turn ends while background agents or shell commands are still running, nothing fires. Claude picks up again when they finish. Agents get as long as they need. Shells get 10 minutes, after which "done" shows anyway, in case it's a server that never exits.
- **Interactive terminal sessions only:** nothing fires in the VS Code/JetBrains extension panel, the Claude desktop app, SDK scripts or `claude -p`.

## Install

macOS / Linux:

```sh
./install.sh              # install or upgrade
./install.sh --dry-run    # show the resulting ~/.claude/settings.json, change nothing
./install.sh --uninstall
```

Windows: double-click `install.cmd`, or:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1     # -DryRun, -Uninstall
```

The installer:
1. copies `attention.sh` (and `attention.ps1`, the Windows helper) to `~/.claude/hooks/`;
2. writes a default `~/.claude/hooks/attention.conf` if you don't have one;
3. backs up `~/.claude/settings.json` to `settings.json.bak-<timestamp>`;
4. adds the hooks to `~/.claude/settings.json`.

**Your existing hooks and settings are kept.** Our hook groups are appended to each event; Claude Code runs all of them side by side. Ours only returns escape sequences and never blocks a tool. Hooks are recognised as ours by `hooks/attention.sh` in their command, so re-running replaces them instead of duplicating them. Uninstall removes only those.

New sessions pick up the hooks; restart any running ones.

> The hooks have to live in your user settings. Claude Code only passes escape sequences through for hooks from your own settings files, so a plugin install wouldn't work.

## What you get

| Terminal | Markers |
|---|---|
| Ghostty | 🔔 in tab title, dock bounce (and a dock badge if notifications with Badges are allowed for Ghostty) |
| iTerm2 | bell icon on tab, dock bounce |
| Terminal.app | dock badge + bounce (enable below) |
| VS Code / Cursor terminal | bell icon on the tab |
| Windows Terminal | yellow tab ring + taskbar progress, taskbar flash |
| PowerShell / cmd window | taskbar flash |
| VS Code on Windows | taskbar flash, bell icon on the tab |

In Ghostty, iTerm2 and kitty, Claude Code sends its own pop-up notification for permission prompts and after 60 s idle. For markers only, turn those off: `/config` → Notifications → disabled.

## One-time setup

**macOS**
- System Settings → Notifications → **your terminal** (Ghostty/iTerm2): allow, with Badges on. The badge stays on the dock icon until you switch back to the terminal, so you can see at a glance that Claude is waiting. Set the alert style to *None* if you only want the badge. If the terminal is listed but switched off, macOS refuses its badge without asking (Ghostty logs `UNErrorDomain Code=1`).
- Terminal.app: Settings → Profiles → Advanced → Bell: tick *Badge app icon* and *Bounce app icon*; untick *Audible bell*, or it beeps at every turn end.
- iTerm2: Settings → Profiles → Terminal: *Silence bell*, *Show bell icon in tabs*.
- VS Code: `"terminal.integrated.enableVisualBell": true`, `"accessibility.signals.terminalBell": {"sound": "off"}`.
- Ghostty (optional): `bell-features = attention,title,border` adds a border around the waiting split. `bell-features = no-title` drops Ghostty's own 🔔, leaving just the hook's mark (`TITLE`).

**Windows**
- Claude Code runs hooks with Git Bash (Git for Windows), which must be installed.
- Windows Terminal (optional): `"bellStyle": ["window", "taskbar"]` in `profiles.defaults`. The hook already flashes the taskbar itself.

## Settings

`~/.claude/hooks/attention.conf` (changes apply to the next event):

| Setting | Default | |
|---|---|---|
| `BELL` | `1` | `0` = no terminal bell |
| `NAG_SEC` | `0` | ring the bell again every N seconds, so the dock icon keeps bouncing (macOS/Linux; stops after 30 min, and on macOS once you've brought the terminal to the front) |
| `TITLE` | `1` | while Claude waits, the tab title shows a mark and the project, e.g. `👀 my-app` (macOS/Linux). On macOS it goes as soon as you start typing or scroll in that tab |
| `MARK_PERMISSION` … `MARK_DONE` | `🔐` `🙋` `📋` `✍️` `⚠️` `👀` | the mark for each kind of wait: permission, question, plan, input, error, done |
| `SHORT_TURN_SEC` | `30` | "done" less than this many seconds after your prompt (or your answer to one of Claude's) shows only the title mark/ring at first (`0` = always ring at once) |
| `SHORT_TURN_BELL_SEC` | `60` | after a short turn, ring the bell this many seconds later if you still haven't responded (`0` = never) |
| `BG_SHELL_MIN` | `10` | when the turn ends with only background shells running, minutes to wait for Claude to resume before "done" (`0` = don't wait). Background agents are always waited for |
| `SKIP_TERMINALS` | `""` | `TERM_PROGRAM` values to ignore, e.g. `"vscode"` |

## How it works

| Claude Code event | Hook |
|---|---|
| `Notification` permission_prompt | `attention.sh wait permission` |
| `Notification` elicitation_dialog, agent_needs_input | `attention.sh wait input` |
| `PreToolUse` AskUserQuestion / ExitPlanMode | `attention.sh wait question` / `wait plan` |
| `PermissionRequest` | `attention.sh arm` (notes whose permission prompt comes next; prints nothing) |
| `Stop` | `attention.sh wait done` |
| `StopFailure` (rate limit, API error) | `attention.sh wait error` |
| `UserPromptSubmit`, `SessionEnd` | `attention.sh off` / `off end` |
| `PostToolUse`, `PostToolUseFailure` | `attention.sh off tool` |

- **Markers:** `wait` returns `{"terminalSequence": "BEL + OSC 9;4;4"}`, and Claude Code writes it to the terminal. The OSC 9;4 tab ring is skipped in Ghostty/iTerm2/ConEmu, which already show Claude's own progress bar. With `NAG_SEC`, a detached job rings the bell again. On macOS it stops once the terminal is the frontmost app (`lsappinfo`): you've seen it, and the dock badge it cleared stays cleared even if you leave without answering. The `TITLE` mark is written a second after the wait starts, once Claude has finished redrawing its own title. Hooks have no controlling terminal, so both write to the `claude` process's tty, found with `ps`.
- **Short turns:** `off` (your prompt) and clearing a permission/question/plan/input wait you answered both note the time in `<state>.acted`. If `Stop` comes less than `SHORT_TURN_SEC` after it, `wait done` returns only the ring (where used) and starts the title job, with no bell. A detached job rings the bell after `SHORT_TURN_BELL_SEC` if the wait is still on, then starts `NAG_SEC`. A tool call that ends a "done", error or busy wait is Claude resuming by itself, so it doesn't count. Blocking waits and errors are never held back.
- **Permission mark:** `arm` notes the tool (`tool_name`, or just the server for MCP tools) next to the agent, and the title shows it after the project.
- **Wait token:** `wait` saves a token per session; the detached jobs stop as soon as it's gone or replaced.
- **Background work:** `Stop` lists the background tasks still running (`background_tasks`). If any is a subagent, workflow, teammate or cloud session, `wait done` only records a "busy" wait and signals nothing. When the work finishes, Claude resumes, and that turn's `Stop` decides. If only shells, monitors or MCP tasks are running, a detached job waits `BG_SHELL_MIN` minutes. If Claude still hasn't resumed by then, the job rings the bell and sets the title, just as an ordinary "done" does.
- **Clearing:** `off` deletes the token, which stops the title and nag jobs, and clears the ring. On macOS, typing or scrolling in the tab ends the wait too, before you submit. The title job watches the tty's access time, which moves whenever Claude reads input, scroll events included (Claude turns on mouse reporting). Focus changes, clicks and the terminal's replies to Claude's queries move it as well, so a read only counts if the terminal is in front and a key was pressed or the wheel scrolled within the last second (`CGEventSourceSecondsSinceLastEventType`, via `osascript`, run only when the tty was read). Reads in the first 7 s are ignored: Claude's queries cluster right after it redraws. After a tool call (`off tool`), only a wait that belongs to that call is cleared. The call has to come from the same agent, so a subagent's tools don't clear the main thread's prompt. For a question or plan, it also has to be the same tool call (`tool_use_id`).
- **Which sessions:** the hook does nothing unless `CLAUDE_CODE_ENTRYPOINT=cli` (an interactive terminal).

## Known limitations

- **Tabs:** the "have you seen it" check for `NAG_SEC` works per app, not per tab. Bringing the terminal to the front on another tab stops the nags too; the waiting tab still shows its 🔔/ring.
- **Typing or scrolling clears the mark:** the check knows the terminal app is in front, not which tab is focused. So switching to the tab with Cmd-Tab, or leaving it with a keyboard shortcut, also counts as typing there. Both only happen while you're on that tab. Scrolling only counts while Claude has mouse reporting on; if your terminal scrolls its own scrollback instead, Claude never sees the scroll. On Linux the mark stays until you submit.
- **Ghostty's dock badge:** Ghostty clears it itself, only when the tab gains focus or you press a key in it. If the bell rang while you were already on that tab, scrolling clears our mark but the badge stays until you type or switch away and back.
- **Background shells:** no hook fires when a background shell finishes, so the hook can't tell a long build from a server that never exits. If a shell is still running after `BG_SHELL_MIN`, "done" shows even though Claude may still pick up later.
- **Short turns:** their bell comes `SHORT_TURN_BELL_SEC` late. With `TITLE=0` in Ghostty or iTerm2 (no tab ring there), a short turn shows nothing until then.
- **Rate limits:** Claude may resume by itself after one. The ⚠️ mark shows anyway; Claude's own title replaces it once it's working again.
- **Older Claude Code:** versions that don't send `background_tasks` on `Stop` get "done" as soon as the main turn ends, even with background work still running.

## Check it works

```sh
sh ~/.claude/hooks/attention.sh test             # marks this tab in 5 s: switch away and watch; Enter clears
sh ~/.claude/hooks/attention.sh test permission  # any kind: permission, question, plan, input, error, done
```

This uses your `attention.conf`, so it shows whether your terminal beeps (fix that in its bell settings above) and how the mark looks. Scripted check of the hook itself:

```sh
echo '{"session_id":"t"}' | CLAUDE_CODE_ENTRYPOINT=cli sh ~/.claude/hooks/attention.sh wait done
# -> {"terminalSequence":"\u0007..."}
```

Live test:
1. Start `claude` in a new terminal tab and ask for something short, staying on the tab: only the title mark shows, no bounce. Switch to another app and wait a minute: the bell/badge follows. Ask for something that takes longer than 30 s and switch away: the bell comes at once.
2. With `NAG_SEC=10`, stay away: the dock icon bounces again every 10 s. Switch to the terminal and back without typing: no more bounces.
3. Answer. The marker clears. On macOS the title mark clears as soon as you start typing or scroll in that tab.

If nothing shows, run `claude --debug` and look for `rejected by the allowlist` or hook errors.

Windows checklist, since this wasn't tested from a Mac:
- yellow tab ring in Windows Terminal;
- taskbar flash in Windows Terminal, a PowerShell window and VS Code. The hook has exited by the time the flash runs, so this checks that the window is found through the console's other processes;
- `claude --debug` shows `PermissionRequest` running before the `permission_prompt` Notification;
- after a short turn, the tab ring shows at once and the taskbar flash only comes a minute later;
- `sh ~/.claude/hooks/attention.sh test` from Git Bash marks the tab and clears it on Enter.

## License

Apache License 2.0. See [LICENSE](LICENSE).
