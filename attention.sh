#!/bin/sh
# Claude Code hook: get your attention when Claude is waiting for you.
#
#   attention.sh wait <permission|question|plan|input|done>
#   attention.sh arm         (PermissionRequest: note whose prompt comes next)
#   attention.sh off [tool|end]
#
# Two tiers:
#   passive  - BEL (tab bell / dock badge / taskbar flash) and, where Claude
#              doesn't draw its own progress bar, an OSC 9;4 "warning" ring on
#              the tab. Immediate, silent, cleared as soon as you respond.
#              With NAG_SEC, the bell rings again while you're not looking.
#   pop-up   - an OS notification, only when Claude is blocked and you're not
#              looking at the terminal: right away for permission/question/plan,
#              after $DELAY seconds for "done". At most one per wait (plus an
#              optional reminder). Answering earlier cancels it.
#
# "Done" holds off while Claude is still waiting on background work: for as
# long as background agents run, and for up to $BG_SHELL_MIN minutes when only
# background shells do. Claude resumes when they finish, and that turn's Stop
# decides.
#
# Hooks have no controlling terminal, so escape sequences go back to Claude
# Code in the `terminalSequence` JSON field. (The NAG_SEC bells and the TITLE
# mark go straight to claude's own tty, found with ps.) Anything slow (pop-ups, Windows
# taskbar flash) runs detached so the hook returns in milliseconds.
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

POPUP=auto          # auto | always | never
DELAY=60            # seconds before the "done" pop-up
SOUND=blocking      # blocking | all | none
BELL=1              # 0 = don't send BEL
REMIND_MIN=0        # >0 = one reminder pop-up after this many minutes
NAG_SEC=0           # >0 = ring the bell again every N seconds while you're not looking
TITLE=1             # 0 = leave the tab title alone
MARK_PERMISSION="🔐" MARK_QUESTION="🙋" MARK_PLAN="📋" MARK_INPUT="✍️" MARK_DONE="🦖"
BG_SHELL_MIN=10     # only background shells left running: wait this long for Claude to resume before "done"
AWAY_SEC=120        # idle longer than this = you're away, even if the terminal is in front
SKIP_TERMINALS=""   # TERM_PROGRAM values to ignore, e.g. "vscode"
BUILTIN_TERMINALS="ghostty iTerm.app kitty"  # Claude's own pop-ups cover permission/input/idle here
MAC_SOUND=Glass
[ -f "$here/attention.conf" ] && . "$here/attention.conf"
DELAY=${CLAUDE_ATTENTION_DELAY:-$DELAY}

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

# You're "looking" if the terminal app is in front and you've touched the
# keyboard/mouse recently. (Windows checks this inside `winps notify`.)
present() {
  [ "$POPUP" = always ] && return 1
  case $os in
    mac)
      front=$(lsappinfo info -only bundleID "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*="\(.*\)".*/\1/p')
      [ -n "$front" ] && [ "$front" = "${__CFBundleIdentifier:-}" ] || return 1
      idle=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
      [ "${idle:-0}" -lt "$AWAY_SEC" ]
      ;;
    *) return 1 ;;
  esac
}

still_waiting() { cur=; IFS= read -r cur 2>/dev/null <"$state"; [ "$cur" = "$token" ]; }

# Pop up unless you're looking or the wait is over. Fails if nothing was shown.
notify() {
  case $os in
    mac)
      present && return 1
      still_waiting || return 1
      snd=""
      [ $sound = 1 ] && snd=" sound name (item 3 of argv)"
      osascript -e 'on run argv' -e "display notification (item 2 of argv) with title (item 1 of argv)$snd" -e 'end run' "Claude Code · $project" "$body" "$MAC_SOUND"
      ;;
    windows)
      always=
      [ "$POPUP" = always ] && always=-Always
      winps notify -Body "$body" -Project "$project" -Tag "$sid" -Sound "$sound" -AwaySec "$AWAY_SEC" \
        -State "$(cygpath -w "$state")" -Token "$token" $always
      ;;
    *) return 1 ;;
  esac
}

# A blocking prompt you were looking at when it appeared isn't re-checked:
# no hook fires when you answer a permission prompt, so a later check can't
# tell "walked away" from "approved a long-running tool".
popup_job() {
  [ "$blocking" = 1 ] || sleep "$DELAY"
  notify || return
  if [ "${REMIND_MIN:-0}" -gt 0 ]; then
    sleep $((REMIND_MIN * 60))
    still_waiting && notify
  fi
}

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

# Put "<mark> <project>" in the tab title. Claude Code sets the title itself,
# so ours goes in after it's done redrawing; Claude's next title update (once
# you respond and it gets to work) puts its own back.
title_job() {
  sleep 1
  still_waiting || return
  printf '\033]2;%s %s\007' "$mark" "$project" >"$tty"
}

# Ring the bell again every NAG_SEC seconds while you're not looking, so the
# dock icon keeps bouncing (each bell bounces once). Gives up after 30 min.
nag_job() {
  n=0
  while [ $n -lt 1800 ]; do
    sleep "$NAG_SEC"
    n=$((n + NAG_SEC))
    still_waiting || return
    present || printf '\a' >"$tty"
  done
}

write_state() {
  printf '%s\nkind=%s\nowner=%s\ntool=%s\n' "$token" "$1" "${owner:-main}" "$tool" >"$state"
}

# Pop-up, tab title and nag jobs for the current wait, all detached.
start_jobs() {
  pop=1
  [ "$POPUP" = never ] && pop=0
  [ -f "$here/attention.mute" ] && pop=0
  [ -n "${SSH_CONNECTION:-}" ] && pop=0
  case " $BUILTIN_TERMINALS " in
    *" ${term:-none} "*) case $kind in permission|input|done) pop=0 ;; esac ;;
  esac
  if [ $pop = 1 ]; then popup_job </dev/null >/dev/null 2>&1 & fi
  # Look up the tty now: once this hook exits, its parent may be gone too.
  title=0 nag=0
  [ "$TITLE" = 1 ] && [ -n "$mark" ] && title=1
  [ "$BELL" = 1 ] && [ "${NAG_SEC:-0}" -gt 0 ] && [ ! -f "$here/attention.mute" ] && nag=1
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
    blocking=1
    [ "$kind" = done ] && blocking=0
    case $kind in
      permission) body="Permission needed" mark=$MARK_PERMISSION ;;
      question) body="Question for you" mark=$MARK_QUESTION ;;
      plan) body="Plan ready for review" mark=$MARK_PLAN ;;
      input) body="Input needed" mark=$MARK_INPUT ;;
      *) body="Done — your turn" mark=$MARK_DONE ;;
    esac
    sound=0
    case $SOUND in all) sound=1 ;; blocking) [ "$blocking" = 1 ] && sound=1 ;; esac

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
    if [ $os = windows ]; then winps clear -Tag "$sid" </dev/null >/dev/null 2>&1 & fi
    ;;
esac
exit 0
