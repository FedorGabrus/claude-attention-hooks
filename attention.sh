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
#   pop-up   - an OS notification, only when Claude is blocked and you're not
#              looking at the terminal: right away for permission/question/plan,
#              after $DELAY seconds for "done". At most one per wait (plus an
#              optional reminder). Answering earlier cancels it.
#
# Hooks can't write to the terminal, so escape sequences go back to Claude
# Code in the `terminalSequence` JSON field. Anything slow (pop-ups, Windows
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

case "$1" in
  wait)
    kind=${2:-done}
    blocking=1
    [ "$kind" = done ] && blocking=0
    case $kind in
      permission) body="Permission needed" ;;
      question) body="Question for you" ;;
      plan) body="Plan ready for review" ;;
      input) body="Input needed" ;;
      *) body="Done — your turn" ;;
    esac
    sound=0
    case $SOUND in all) sound=1 ;; blocking) [ "$blocking" = 1 ] && sound=1 ;; esac

    # Whose wait this is, so `off tool` can tell its tool calls from others'.
    owner=
    [ "$kind" = permission ] && [ -f "$state.req" ] && IFS= read -r owner <"$state.req"
    [ -n "$owner" ] || field agent_id owner
    tool=
    case $kind in question|plan) field tool_use_id tool ;; esac

    token="$$.${RANDOM:-0}"
    printf '%s\nkind=%s\nowner=%s\ntool=%s\n' "$token" "$kind" "${owner:-main}" "$tool" >"$state"

    seq=""
    [ "$BELL" = 1 ] && seq='\u0007'
    [ $progress = 1 ] && seq="$seq"'\u001b]9;4;4;100\u0007'
    emit "$seq"

    if [ $os = windows ]; then winps flash </dev/null >/dev/null 2>&1 & fi

    pop=1
    [ "$POPUP" = never ] && pop=0
    [ -f "$here/attention.mute" ] && pop=0
    [ -n "${SSH_CONNECTION:-}" ] && pop=0
    case " $BUILTIN_TERMINALS " in
      *" ${term:-none} "*) case $kind in permission|input|done) pop=0 ;; esac ;;
    esac
    if [ $pop = 1 ]; then popup_job </dev/null >/dev/null 2>&1 & fi
    ;;
  off)
    # Only reached when this wait should end (see the checks at the top).
    rm -f "$state"
    [ $progress = 1 ] && emit '\u001b]9;4;0;0\u0007'
    if [ $os = windows ]; then winps clear -Tag "$sid" </dev/null >/dev/null 2>&1 & fi
    ;;
esac
exit 0
