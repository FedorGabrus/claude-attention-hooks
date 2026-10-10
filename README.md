# Claude Code attention hooks

Know when Claude Code is waiting for you, so a long session doesn't need watching.
Works in macOS and Windows terminals.

- **Quiet marker, always:** the bell (🔔 on the tab, a dock badge/bounce, a taskbar flash) and, where supported, a ring on the tab. It appears at once, makes no sound, and clears as soon as you respond.
- **Pop-up, only when Claude is blocked and you're not looking:** right away for a permission prompt, a question or a plan to approve. After 60 s for "done, your turn". At most one per wait. Answering earlier cancels it.
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

| Terminal | Quiet marker | Pop-up |
|---|---|---|
| Ghostty | 🔔 in tab title, dock bounce (and a dock badge if notifications with Badges are allowed for Ghostty) | Claude's own (permission/idle) + hook (questions, plans) |
| iTerm2 | bell icon on tab, dock bounce | Claude's own + hook (questions, plans) |
| Terminal.app | dock badge + bounce (enable below) | hook |
| VS Code / Cursor terminal | bell icon on the tab | hook |
| Windows Terminal | yellow tab ring + taskbar progress, taskbar flash | hook (toast) |
| PowerShell / cmd window | taskbar flash | hook (toast) |
| VS Code on Windows | taskbar flash, bell icon on the tab | hook (toast) |

In Ghostty, iTerm2 and kitty, Claude Code already sends its own notification for permission prompts and after 60 s idle. It's focus-aware, and clicking it opens the right tab, so the hook leaves those events to it. Claude's own notification never covers AskUserQuestion or plan approval, so the hook covers those. Claude's own only appear if the terminal may post notifications. If you keep the terminal's notifications off, set `BUILTIN_TERMINALS=""` so the hook sends them instead.

## One-time setup

**macOS**
- System Settings → Notifications → **Script Editor**: allow. The hook's pop-ups come from `osascript`. Set the style to *Alerts* (*Persistent*) to keep them on screen until you dismiss them.
- System Settings → Notifications → **your terminal** (Ghostty/iTerm2): allow, with Badges on. The badge stays on the dock icon until you switch back to the terminal, so you can see at a glance that Claude is waiting. If the terminal is listed but switched off, macOS refuses its badge without asking (Ghostty logs `UNErrorDomain Code=1`), and Claude's own pop-ups don't appear either.
- Terminal.app: Settings → Profiles → Advanced → Bell: tick *Badge app icon* and *Bounce app icon*; untick *Audible bell*, or it beeps at every turn end.
- iTerm2: Settings → Profiles → Terminal: *Silence bell*, *Show bell icon in tabs*.
- VS Code: `"terminal.integrated.enableVisualBell": true`, `"accessibility.signals.terminalBell": {"sound": "off"}`.
- Ghostty (optional): `bell-features = attention,title,border` adds a border around the waiting split. `bell-features = no-title` drops Ghostty's own 🔔, leaving just the hook's mark (`TITLE`).

**Windows**
- Claude Code runs hooks with Git Bash (Git for Windows), which must be installed.
- Pop-ups are toasts from *Windows PowerShell*: keep its notifications on in Settings → System → Notifications.
- Windows Terminal (optional): `"bellStyle": ["window", "taskbar"]` in `profiles.defaults`. The hook already flashes the taskbar itself.

## Settings

`~/.claude/hooks/attention.conf` (changes apply to the next event):

| Setting | Default | |
|---|---|---|
| `POPUP` | `auto` | `auto` = only when you're not looking · `always` · `never` (markers only) |
| `DELAY` | `60` | seconds before the "done" pop-up |
| `SOUND` | `blocking` | which pop-ups play a sound: `blocking` (permission/question/plan) · `all` · `none` |
| `BELL` | `1` | `0` = no terminal bell |
| `REMIND_MIN` | `0` | one reminder after N minutes if still unanswered |
| `NAG_SEC` | `0` | ring the bell again every N seconds while you're not looking, so the dock icon keeps bouncing (macOS/Linux; stops after 30 min) |
| `TITLE` | `1` | while Claude waits, the tab title shows a mark and the project, e.g. `🦖 my-app` (macOS/Linux) |
| `MARK_PERMISSION` … `MARK_DONE` | `🔐` `🙋` `📋` `✍️` `🦖` | the mark for each kind of wait: permission, question, plan, input, done |
| `AWAY_SEC` | `120` | idle this long counts as away, even with the terminal in front |
| `SKIP_TERMINALS` | `""` | `TERM_PROGRAM` values to ignore, e.g. `"vscode"` |
| `BUILTIN_TERMINALS` | `"ghostty iTerm.app kitty"` | terminals where Claude's own pop-ups are left to do their job |

Mute pop-ups for a while with `touch ~/.claude/hooks/attention.mute`; delete the file to unmute.

## How it works

| Claude Code event | Hook |
|---|---|
| `Notification` permission_prompt | `attention.sh wait permission` |
| `Notification` elicitation_dialog, agent_needs_input | `attention.sh wait input` |
| `PreToolUse` AskUserQuestion / ExitPlanMode | `attention.sh wait question` / `wait plan` |
| `PermissionRequest` | `attention.sh arm` (notes whose permission prompt comes next; prints nothing) |
| `Stop` | `attention.sh wait done` |
| `UserPromptSubmit`, `SessionEnd` | `attention.sh off` / `off end` |
| `PostToolUse`, `PostToolUseFailure` | `attention.sh off tool` |

- **Markers:** `wait` returns `{"terminalSequence": "BEL + OSC 9;4;4"}`, and Claude Code writes it to the terminal. The OSC 9;4 tab ring is skipped in Ghostty/iTerm2/ConEmu, which already show Claude's own progress bar. With `NAG_SEC`, a detached job rings the bell again while you're not looking. The `TITLE` mark is written a second after the wait starts, once Claude has finished redrawing its own title. Hooks have no controlling terminal, so both write to the `claude` process's tty, found with `ps`.
- **Pop-ups:** `wait` saves a token per session and starts a detached job. A blocking prompt is checked right away and the "done" turn after `DELAY` seconds. The check is whether you're looking: is the terminal the frontmost app (macOS `lsappinfo`, Windows `GetForegroundWindow`), and have you used the keyboard or mouse recently? If you're not looking, and the wait is still on, it shows an `osascript` notification or a Windows toast. If you were looking when a blocking prompt appeared, there's no later re-check: no hook fires when you answer a permission prompt, so a re-check can't tell whether you walked away or approved a long-running tool. Windows toasts are tagged by session, so they replace each other and are removed when you respond.
- **Clearing:** `off` deletes the token, which cancels pending pop-ups, and clears the ring. After a tool call (`off tool`), only a wait that belongs to that call is cleared. The call has to come from the same agent, so a subagent's tools don't clear the main thread's prompt. For a question or plan, it also has to be the same tool call (`tool_use_id`).
- **Which sessions:** the hook does nothing unless `CLAUDE_CODE_ENTRYPOINT=cli` (an interactive terminal). Over SSH you get markers only.

## Known limitations

- **Tabs:** the "are you looking" check works per app, not per tab. If the terminal is in front but you're on another tab, there's no pop-up; that tab still shows its 🔔/ring.
- **Background agents:** `Stop` fires when the main turn ends even if background agents keep working. Outside Ghostty/iTerm2/kitty, a "Done" pop-up can therefore arrive while Claude is still busy in the background.
- **macOS banners:** `osascript` banners can't be removed from code once shown, and clicking one doesn't focus the terminal.
- **Prompts you saw:** if the terminal was in front when a permission prompt, question or plan appeared, you get no pop-up later, even if you walk away without answering. The tab marker stays.
- **Reminders:** with `REMIND_MIN` set, a reminder can still fire while a long-running tool works, if you approved it after the first pop-up.

## Check it works

```sh
echo '{"session_id":"t"}' | CLAUDE_CODE_ENTRYPOINT=cli sh ~/.claude/hooks/attention.sh wait done
# -> {"terminalSequence":"\u0007..."}
```

Live test:
1. Start `claude` in a new terminal tab and ask for something short. Switch to another app. You should see the bell/badge, then one pop-up after ~60 s.
2. Ask Claude to ask you a question (AskUserQuestion) and switch away. You should get a pop-up right away.
3. Answer. The marker clears.
4. For quicker testing, put `DELAY=10` in `attention.conf`.

If nothing shows, run `claude --debug` and look for `rejected by the allowlist` or hook errors.

Windows checklist, since this wasn't tested from a Mac:
- toast after a permission prompt while another app is focused;
- yellow tab ring in Windows Terminal;
- taskbar flash in Windows Terminal, a PowerShell window and VS Code. The hook has exited by the time the flash runs, so this checks that the window is found through the console's other processes;
- no toast when the terminal is in front and you're active;
- the toast disappears from Action Center after you respond, including when you answer within a second or two of the prompt;
- the "Done — your turn" toast shows the em dash correctly;
- `claude --debug` shows `PermissionRequest` running before the `permission_prompt` Notification.
