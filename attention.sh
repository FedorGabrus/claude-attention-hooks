#!/bin/sh
# Claude Code hook: get your attention when Claude is waiting for you.
#
#   attention.sh wait <permission|question|plan|input|done>
#   attention.sh arm         (PermissionRequest: note whose prompt comes next)
#   attention.sh off [tool|end]
#
# Quiet markers only, no pop-ups: BEL (tab bell / dock badge / taskbar flash)
# and, where Claude doesn't draw its own progress bar, an OSC 9;4 "warning"
# ring on the tab. Immediate, silent, cleared as soon as you respond. With
# NAG_SEC, the bell rings again until you've seen it.
#
# "Done" holds off while Claude is still waiting on background work: for as
# long as background agents run, and for up to $BG_SHELL_MIN minutes when only
# background shells do. Claude resumes when they finish, and that turn's Stop
# decides.
#
# Hooks have no controlling terminal, so escape sequences go back to Claude
# Code in the `terminalSequence` JSON field. (The NAG_SEC bells and the TITLE
# mark go straight to claude's own tty, found with ps.) Anything slow (the
# Windows taskbar flash) runs detached so the hook returns in milliseconds.
# Works in macOS sh and Git Bash on Windows. Settings: attention.conf.

input=$(cat)

# --- Only interactive terminal sessions -------------------------------------
# Skips the VS Code/JetBrains extension panel, the desktop app, the SDK,
# `claude -p` (entrypoint becomes sdk-cli) and remote sessions.
[ "${CLAUDE_CODE_ENTRYPOINT:-}" = cli ] || exit 0
[ -z "${CLAUDE_CODE_REMOTE:-}" ] || exit 0

# field NAME VAR: set VAR to the string field NAME of the hook input, using
# builtins only. Ids are [A-Za-z0-9_.-]; anything else reads as empty.
field() {
  _v=
  case $input in *"\"$1\""*)
    _v=${input#*\""$1"\"}; _v=${_v#*:}; _v=${_v#"${_v%%[! ]*}"}
    case $_v in \"*) _v=${_v#\"}; _v=${_v%%\"*} ;; *) _v= ;; esac ;;
  esac
  case $_v in *[!A-Za-z0-9_.-]*) _v= ;; esac
  eval "$2=\$_v"
}

field session_id sid
[ -n "$sid" ] || sid=default
state="${TMPDIR:-${TEMP:-/tmp}}/claude-attention-$sid"

# PermissionRequest comes just before the permission prompt's Notification,
# which doesn't say whose prompt it is. Print nothing here: PermissionRequest
# output is read as a permission decision.
if [ "$1" = arm ]; then
  field agent_id owner
  printf '%s\n' "${owner:-main}" >"$state.req"
  exit 0
fi

# `off` runs after every tool call: decide with builtins only whether there's
# anything to clear before forking or reading the conf.
if [ "$1" = off ]; then
  [ "${2:-}" = end ] && rm -f "$state.req"
  [ -f "$state" ] || exit 0
  # After a tool call, only clear the wait it belongs to: same agent (a
  # subagent's tools don't answer the main thread), and for a question or
  # plan, the very tool call that asked.
  if [ "${2:-}" = tool ]; then
    w_kind= w_owner= w_tool=
    while IFS='=' read -r k v; do
      case $k in kind) w_kind=$v ;; owner) w_owner=$v ;; tool) w_tool=$v ;; esac
    done <"$state"
    field agent_id me
    [ "${me:-main}" = "${w_owner:-main}" ] || exit 0
    case $w_kind in question|plan) field tool_use_id t; [ "$t" = "$w_tool" ] || exit 0 ;; esac
  fi
fi

here=$(cd "$(dirname "$0")" && pwd)

BELL=1              # 0 = don't send BEL
NAG_SEC=0           # >0 = ring the bell again every N seconds until you've seen it
TITLE=1             # 0 = leave the tab title alone
MARK_PERMISSION="🔐" MARK_QUESTION="🙋" MARK_PLAN="📋" MARK_INPUT="✍️" MARK_DONE="👀"
BG_SHELL_MIN=10     # only background shells left running: wait this long for Claude to resume before "done"
SKIP_TERMINALS=""   # TERM_PROGRAM values to ignore, e.g. "vscode"
[ -f "$here/attention.conf" ] && . "$here/attention.conf"

# kitty doesn't set TERM_PROGRAM.
term=${TERM_PROGRAM:-}
if [ -z "$term" ] && { [ -n "${KITTY_WINDOW_ID:-}" ] || [ "${TERM:-}" = xterm-kitty ]; }; then
  term=kitty
fi
case " $SKIP_TERMINALS " in *" ${term:-none} "*) exit 0 ;; esac

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  Darwin) os=mac ;;
  *) os=other ;;
esac

project=${CLAUDE_PROJECT_DIR:-$PWD}
project=${project%/}
project=${project##*/}

# Claude Code draws its own OSC 9;4 progress bar in these terminals; ours
# would fight with it, so the tab ring is only used elsewhere (e.g. Windows
# Terminal).
progress=1
case "$term" in ghostty|iTerm.app) progress=0 ;; esac
[ -n "${ConEmuPID:-}" ] && progress=0

emit() { [ -n "$1" ] && printf '{"terminalSequence":"%s"}\n' "$1"; }

[ $os = windows ] && ps1=$(cygpath -w "$here/attention.ps1")
winps() {
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps1" "$@"
}

# Is the terminal app in front? (macOS)
term_in_front() {
  front=$(lsappinfo info -only bundleID "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*="\(.*\)".*/\1/p')
  [ -n "$front" ] && [ "$front" = "${__CFBundleIdentifier:-}" ]
}

still_waiting() { cur=; IFS= read -r cur 2>/dev/null <"$state"; [ "$cur" = "$token" ]; }

# The hook has no controlling terminal; the claude process up the tree does.
claude_tty() {
  p=$PPID
  while [ "${p:-1}" -gt 1 ]; do
    set -- $(ps -o tty= -o ppid= -p "$p" 2>/dev/null)
    case ${1:-} in tty*|pts/*) [ -w "/dev/$1" ] && echo "/dev/$1" && return ;; esac
    p=${2:-1}
  done
  return 1
}

# Did you just type into this tab? Claude reads its tty when there's input,
# which moves the tty's access time. Other things do too: focus changes,
# scrolling, clicks, and the terminal answering Claude's queries (a burst of
# them right after Claude draws). So a read only counts with the terminal in
# front and a key pressed in the last second. macOS only.
typed_here() {
  t=$(stat -f %a "$tty" 2>/dev/null) || return 1
  [ "$t" = "$read_at" ] && return 1
  read_at=$t
  [ $n -ge 12 ] || return 1   # still settling after Claude's last redraw
  term_in_front || return 1
  key=$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); $.CGEventSourceSecondsSinceLastEventType(1, 10) < 1' 2>/dev/null)
  [ "$key" = true ]
}

# Put "<mark> <project>" in the tab title. Claude Code sets the title itself,
# so ours goes in after it's done redrawing. On macOS, once you start typing
# in the tab the wait counts as answered: the mark, ring and nags go.
# Otherwise Claude's next title update, once you respond and it gets to work,
# puts its own back.
title_job() {
  sleep 1
  still_waiting || return
  printf '\033]2;%s %s\007' "$mark" "$project" >"$tty"
  [ $os = mac ] || return
  read_at=$(stat -f %a "$tty" 2>/dev/null) || return
  n=0
  while [ $n -lt 86400 ]; do   # half-seconds: gives up after 12 h
    sleep 0.5
    n=$((n + 1))
    still_waiting || return
    typed_here || continue
    rm -f "$state"
    clear=
    [ $progress = 1 ] && clear='\033]9;4;0;0\007'
    printf "\033]2;%s\007$clear" "$project" >"$tty"
    return
  done
}

# Ring the bell again every NAG_SEC seconds, so the dock icon keeps bouncing
# (each bell bounces once). On macOS it stops for good once the terminal comes
# to the front: you've seen it, and the dock badge it cleared stays cleared
# even if you leave without answering. Gives up after 30 min.
nag_job() {
  n=0
  while [ $n -lt 1800 ]; do
    sleep 1
    n=$((n + 1))
    still_waiting || return
    [ $os = mac ] && term_in_front && return
    [ $((n % NAG_SEC)) = 0 ] && printf '\a' >"$tty"
  done
}

write_state() {
  printf '%s\nkind=%s\nowner=%s\ntool=%s\n' "$token" "$1" "${owner:-main}" "$tool" >"$state"
}

# Tab title and nag jobs for the current wait, both detached.
start_jobs() {
  # Look up the tty now: once this hook exits, its parent may be gone too.
  title=0 nag=0
  [ "$TITLE" = 1 ] && [ -n "$mark" ] && title=1
  [ "$BELL" = 1 ] && [ "${NAG_SEC:-0}" -gt 0 ] && nag=1
  if [ $os != windows ] && [ $title$nag != 00 ] && { [ -n "${tty:-}" ] || tty=$(claude_tty); }; then
    [ $title = 1 ] && title_job </dev/null >/dev/null 2>&1 &
    [ $nag = 1 ] && nag_job </dev/null >/dev/null 2>&1 &
  fi
}

# Only background shells were left running when the turn ended. If Claude
# hasn't resumed after BG_SHELL_MIN minutes (a server that never exits, say),
# it's your turn after all: signal "done" from here, straight to the tty.
late_done_job() {
  sleep $((BG_SHELL_MIN * 60))
  still_waiting || return
  seq=
  [ "$BELL" = 1 ] && seq='\a'
  [ $progress = 1 ] && seq="$seq"'\033]9;4;4;100\007'
  [ -n "$seq" ] && [ -n "${tty:-}" ] && printf "$seq" >"$tty"
  if [ $os = windows ]; then winps flash; fi
  start_jobs
}

case "$1" in
  wait)
    kind=${2:-done}
    case $kind in
      permission) mark=$MARK_PERMISSION ;;
      question) mark=$MARK_QUESTION ;;
      plan) mark=$MARK_PLAN ;;
      input) mark=$MARK_INPUT ;;
      *) mark=$MARK_DONE ;;
    esac

    # Whose wait this is, so `off tool` can tell its tool calls from others'.
    owner=
    [ "$kind" = permission ] && [ -f "$state.req" ] && IFS= read -r owner <"$state.req"
    [ -n "$owner" ] || field agent_id owner
    tool=
    case $kind in question|plan) field tool_use_id tool ;; esac

    # Is Claude still waiting on background work? Stop lists the running
    # background tasks in background_tasks (older versions don't send it).
    # Quotes inside descriptions and commands are escaped, so only real
    # "type" fields match.
    bg=
    if [ "$kind" = done ]; then
      case $input in *'"background_tasks":['*)
        bt=${input#*'"background_tasks":['}
        bt=${bt%%'"session_crons"'*}
        case $bt in
          *'"type":"subagent"'*|*'"type":"workflow"'*|*'"type":"teammate"'*|*'"type":"cloud session"'*) bg=agent ;;
          *'"type":"shell"'*|*'"type":"monitor"'*|*'"type":"MCP task"'*) bg=shell ;;
        esac ;;
      esac
      [ "$bg" = shell ] && [ "${BG_SHELL_MIN:-0}" -le 0 ] && bg=
    fi

    token="$$.${RANDOM:-0}"

    # Claude resumes by itself when background work finishes, and that turn's
    # Stop decides. Agents always finish; a shell may be a server that never
    # does, so after BG_SHELL_MIN "done" is signalled anyway.
    if [ -n "$bg" ]; then
      write_state busy
      if [ $bg = shell ]; then
        tty=
        [ $os != windows ] && tty=$(claude_tty)
        late_done_job </dev/null >/dev/null 2>&1 &
      fi
      exit 0
    fi

    write_state "$kind"

    seq=""
    [ "$BELL" = 1 ] && seq='\u0007'
    [ $progress = 1 ] && seq="$seq"'\u001b]9;4;4;100\u0007'
    emit "$seq"

    if [ $os = windows ]; then winps flash </dev/null >/dev/null 2>&1 & fi

    tty=
    start_jobs
    ;;
  off)
    # Only reached when this wait should end (see the checks at the top).
    rm -f "$state"
    [ $progress = 1 ] && emit '\u001b]9;4;0;0\u0007'
    ;;
esac
exit 0
