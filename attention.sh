#!/bin/sh
# Claude Code hook: get your attention when Claude is waiting for you.
#
#   attention.sh wait <permission|question|plan|input|error|done>
#   attention.sh arm         (PermissionRequest: note whose prompt comes next)
#   attention.sh off [tool|end]
#   attention.sh test [kind] (by hand: mark this tab in 5 s, to check the setup)
#
# Quiet markers only, no pop-ups: BEL (tab bell / dock badge / taskbar flash)
# and, where Claude doesn't draw its own progress bar, an OSC 9;4 "warning"
# ring on the tab. Immediate, silent, cleared as soon as you respond. With
# NAG_SEC, the bell rings again until you've seen it.
#
# "Done" after a short turn (you were probably watching) only marks the title
# and ring at first; the bell follows after SHORT_TURN_BELL_SEC if you still
# haven't responded.
#
# "Done" holds off while Claude is still waiting on background work. Agents,
# and any other in-flight task that is not a shell, monitor, or MCP task
# (including a type added in a newer Claude), wait until Claude resumes. Only
# those three are timed: after $BG_SHELL_MIN minutes "done" shows anyway,
# because a shell may be a server that never exits. Claude's next Stop decides.
#
# Hooks have no controlling terminal, so escape sequences go back to Claude
# Code in the `terminalSequence` JSON field. (The NAG_SEC bells and the TITLE
# mark go straight to claude's own tty, found with ps.) Anything slow (the
# Windows taskbar flash) runs detached so the hook returns in milliseconds.
# Works in macOS sh and Git Bash on Windows. Settings: attention.conf.

# One awk pass over the hook JSON. Prints sid, agent_id, tool_name, tool_use_id,
# psrc (UserPromptSubmit "source"), and bg (agent|shell|empty). String fields
# keep only [A-Za-z0-9_.-]; anything else is empty. bg is the background_tasks
# class: an agent-like or unknown type wins over shell/monitor/MCP task.
# No jq. The payload stays in awk, not in the shell.
emit_fields() {
  awk '
function grab(s, key,    pat, start, n, rest, c, val, sp) {
  pat = "\"" key "\""
  start = 1
  while (start <= length(s)) {
    n = index(substr(s, start), pat)
    if (n == 0) return ""
    start = start + n - 1
    rest = substr(s, start + length(pat))
    sp = 1
    while (substr(rest, sp, 1) ~ /[[:space:]]/) sp++
    rest = substr(rest, sp)
    if (substr(rest, 1, 1) != ":") { start++; continue }
    rest = substr(rest, 2)
    sp = 1
    while (substr(rest, sp, 1) ~ /[[:space:]]/) sp++
    rest = substr(rest, sp)
    if (substr(rest, 1, 1) != "\"") { start++; continue }
    rest = substr(rest, 2)
    val = ""
    while ((c = substr(rest, 1, 1)) != "" && c != "\"") {
      if (c !~ /[A-Za-z0-9_.-]/) return ""
      val = val c
      rest = substr(rest, 2)
    }
    if (c != "\"") return ""
    return val
  }
  return ""
}
function is_agent(t) {
  return t == "subagent" || t == "workflow" || t == "teammate" || t == "cloud session" || t == "dream" || t == "auto-mode scan" || t == "memory import"
}
function is_shell(t) {
  return t == "shell" || t == "monitor" || t == "MCP task"
}
function classify(s,    i, r, j, rest, c, t, saw) {
  i = index(s, "\"background_tasks\":[")
  if (i == 0) i = index(s, "\"background_tasks\": [")
  if (i == 0) return ""
  r = substr(s, i)
  j = index(r, "\"session_crons\"")
  if (j > 0) r = substr(r, 1, j - 1)
  saw = ""
  rest = r
  while (match(rest, /"type"[[:space:]]*:[[:space:]]*"/)) {
    rest = substr(rest, RSTART + RLENGTH)
    t = ""
    while ((c = substr(rest, 1, 1)) != "" && c != "\"") {
      t = t c
      rest = substr(rest, 2)
    }
    if (c == "\"") rest = substr(rest, 2)
    if (is_agent(t) || (t != "" && !is_shell(t))) return "agent"
    if (is_shell(t)) saw = "shell"
  }
  return saw
}
{ buf = buf $0 "\n" }
END {
  printf "sid=%s\n", grab(buf, "session_id")
  printf "agent_id=%s\n", grab(buf, "agent_id")
  printf "tool_name=%s\n", grab(buf, "tool_name")
  printf "tool_use_id=%s\n", grab(buf, "tool_use_id")
  printf "psrc=%s\n", grab(buf, "source")
  printf "bg=%s\n", classify(buf)
}
'
}

load_fields() {
  sid= agent_id= tool_name= tool_use_id= psrc= bg=
  while IFS='=' read -r k v; do
    case $k in
      sid) sid=$v ;;
      agent_id) agent_id=$v ;;
      tool_name) tool_name=$v ;;
      tool_use_id) tool_use_id=$v ;;
      psrc) psrc=$v ;;
      bg) case $v in agent|shell) bg=$v ;; esac ;;
    esac
  done
}

# --- Only interactive terminal sessions -------------------------------------
# Skips the VS Code/JetBrains extension panel, the desktop app, the SDK,
# `claude -p` (entrypoint becomes sdk-cli) and remote sessions. `test` is run
# by hand, outside Claude, with nothing on stdin.
if [ "${1:-}" != test ]; then
  if [ "${CLAUDE_CODE_ENTRYPOINT:-}" != cli ] || [ -n "${CLAUDE_CODE_REMOTE:-}" ]; then
    cat >/dev/null
    exit 0
  fi
  # PostToolUse runs on every tool call and carries the tool result. The
  # session id is at the front; when nothing is waiting, drain the rest and
  # return without holding the payload in the shell.
  inpre=
  trap '[ -n "$inpre" ] && rm -f "$inpre"' EXIT
  if [ "$1" = off ] && [ "${2:-}" = tool ]; then
    inpre=$(mktemp "${TMPDIR:-/tmp}/claude-attention-in.XXXXXX")
    dd bs=4096 count=1 2>/dev/null >"$inpre" || true
    nbytes=$(wc -c <"$inpre" | tr -d ' ')
    load_fields <<EOF
$(emit_fields <"$inpre")
EOF
    if [ "$nbytes" -lt 4096 ] || [ -n "$sid" ]; then
      [ -n "$sid" ] || sid=default
      state="${TMPDIR:-${TEMP:-/tmp}}/claude-attention-$sid"
      if [ ! -f "$state" ]; then
        [ "$nbytes" -eq 4096 ] && cat >/dev/null
        exit 0
      fi
    fi
    if [ "$nbytes" -eq 4096 ]; then
      load_fields <<EOF
$(cat "$inpre" - | emit_fields)
EOF
    fi
  else
    load_fields <<EOF
$(emit_fields)
EOF
  fi
fi

[ -n "$sid" ] || sid=default
state="${TMPDIR:-${TEMP:-/tmp}}/claude-attention-$sid"

# When you last sent a prompt or answered one: "done" soon after is a short turn.
acted() { date +%s >"$state.acted"; }

# PermissionRequest comes just before the permission prompt's Notification,
# which doesn't say whose prompt it is or for which tool. Print nothing here:
# PermissionRequest output is read as a permission decision. Line 3 of .req is
# the full tool name, so a later tool call can tell this prompt from others.
if [ "$1" = arm ]; then
  owner=${agent_id:-main}
  ptool=$tool_name
  case $ptool in mcp__*) ptool=${ptool#mcp__}; ptool=${ptool%%__*} ;; esac   # MCP: just the server
  printf '%s\n%s\n%s\n' "$owner" "$ptool" "$tool_name" >"$state.req"
  exit 0
fi

# `off` decides whether there is anything to clear before reading the conf.
if [ "$1" = off ]; then
  case ${2:-} in
    '')
      # UserPromptSubmit. A loop, cron, poll, or other injected turn is not you
      # answering, and must not start the short-turn clock. An omitted source
      # is an older Claude Code that only sent real prompts.
      case $psrc in ''|user) acted ;; *) exit 0 ;; esac
      ;;
    end) rm -f "$state.req" "$state.acted" ;;
  esac
  [ -f "$state" ] || exit 0
  # After a tool call, only clear the wait it belongs to: same agent (a
  # subagent's tools don't answer the main thread). A question or plan has to
  # be the tool call that asked. A permission has to be the tool that asked
  # (an empty tool is an older state file: any tool from this agent clears it).
  if [ "${2:-}" = tool ]; then
    w_kind= w_owner= w_tool=
    while IFS='=' read -r k v; do
      case $k in kind) w_kind=$v ;; owner) w_owner=$v ;; tool) w_tool=$v ;; esac
    done <"$state"
    [ "${agent_id:-main}" = "${w_owner:-main}" ] || exit 0
    case $w_kind in
      question|plan) [ "$tool_use_id" = "$w_tool" ] || exit 0 ;;
      permission) [ -z "$w_tool" ] || [ "$tool_name" = "$w_tool" ] || exit 0 ;;
    esac
  fi
fi

here=$(cd "$(dirname "$0")" && pwd)

BELL=1              # 0 = don't send BEL
NAG_SEC=0           # >0 = ring the bell again every N seconds until you've seen it
TITLE=1             # 0 = leave the tab title alone
MARK_PERMISSION="🔐" MARK_QUESTION="🙋" MARK_PLAN="📋" MARK_INPUT="✍️" MARK_ERROR="⚠️" MARK_DONE="👀"
SHORT_TURN_SEC=30   # "done" this soon after your prompt or answer: title/ring only at first (0 = always ring)
SHORT_TURN_BELL_SEC=60  # ...then the bell if you still haven't responded (0 = never)
BG_SHELL_MIN=10     # only background shells left running: wait this long for Claude to resume before "done"
SKIP_TERMINALS=""   # TERM_PROGRAM values to ignore, e.g. "vscode"
[ -f "$here/attention.conf" ] && . "$here/attention.conf"

# kitty doesn't set TERM_PROGRAM.
term=${TERM_PROGRAM:-}
if [ -z "$term" ] && { [ -n "${KITTY_WINDOW_ID:-}" ] || [ "${TERM:-}" = xterm-kitty ]; }; then
  term=kitty
fi
case " $SKIP_TERMINALS " in *" ${term:-none} "*)
  [ "$1" = test ] && echo "SKIP_TERMINALS in attention.conf includes \"$term\": nothing shows in this terminal."
  exit 0 ;;
esac

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

claude_pid=

still_waiting() {
  cur=
  IFS= read -r cur 2>/dev/null <"$state" || return 1
  [ "$cur" = "$token" ] || return 1
  # A crash leaves the state file behind; stop once claude itself is gone.
  if [ -n "$claude_pid" ]; then
    kill -0 "$claude_pid" 2>/dev/null || return 1
  fi
  return 0
}

# The hook has no controlling terminal; the claude process up the tree does.
# Sets tty and claude_pid in this shell (a command substitution would drop the
# pid). Restores $1/$2; ps parsing uses them.
claude_tty() {
  _save1=$1 _save2=$2
  tty=
  p=$PPID
  _found=1
  while [ "${p:-1}" -gt 1 ]; do
    set -- $(ps -o tty= -o ppid= -p "$p" 2>/dev/null)
    case ${1:-} in
      tty*|pts/*)
        if [ -w "/dev/$1" ]; then
          claude_pid=$p
          tty=/dev/$1
          _found=0
          break
        fi
        ;;
    esac
    p=${2:-1}
  done
  set -- "$_save1" "$_save2"
  return $_found
}

# Did you just type or scroll in this tab? Claude reads its tty when there's
# input (scrolling included: Claude turns on mouse reporting), which moves the
# tty's access time. Other things do too: focus changes, clicks, and the
# terminal answering Claude's queries (a burst of them right after Claude
# draws). So a read only counts with the terminal in front and a key press
# (event type 10) or scroll (22) in the last second. macOS only.
used_here() {
  t=$(stat -f %a "$tty" 2>/dev/null) || return 1
  [ "$t" = "$read_at" ] && return 1
  read_at=$t
  [ $n -ge 12 ] || return 1   # still settling after Claude's last redraw
  term_in_front || return 1
  used=$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); [10, 22].some(e => $.CGEventSourceSecondsSinceLastEventType(1, e) < 1)' 2>/dev/null)
  [ "$used" = true ]
}

# Put "<mark> <project>" (permission: "<mark> <project> · <tool>") in the tab
# title. Claude Code sets the title itself, so ours goes in after it's done
# redrawing. On macOS, once you start typing or scroll in the tab the wait
# counts as answered: the mark, ring and nags go. Otherwise Claude's next title
# update, once you respond and it gets to work, puts its own back.
title_job() {
  sleep 1
  still_waiting || return
  printf '\033]2;%s %s\007' "$mark" "$label" >"$tty"
  [ $os = mac ] || return
  read_at=$(stat -f %a "$tty" 2>/dev/null) || return
  n=0
  while [ $n -lt 86400 ]; do   # half-seconds: gives up after 12 h
    sleep 0.5
    n=$((n + 1))
    still_waiting || return
    used_here || continue
    rm -f "$state"
    acted
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

# Detached jobs survive the hook exiting. dash sends them SIGHUP; ignore it.
# Drop the EXIT trap so a job does not remove the input temp file early.
spawn() {
  (trap '' HUP; trap - EXIT; "$@") </dev/null >/dev/null 2>&1 &
}

# Detached jobs for the current wait: "title", "nag" or both.
start_jobs() {
  title=0 nag=0
  case " $* " in *" title "*) [ "$TITLE" = 1 ] && [ -n "$mark" ] && title=1 ;; esac
  case " $* " in *" nag "*) [ "$BELL" = 1 ] && [ "${NAG_SEC:-0}" -gt 0 ] && nag=1 ;; esac
  # Look up the tty now: once this hook exits, its parent may be gone too.
  if [ $os != windows ] && [ $title$nag != 00 ] && { [ -n "${tty:-}" ] || claude_tty; }; then
    [ $title = 1 ] && spawn title_job
    [ $nag = 1 ] && spawn nag_job
  fi
}

# Signal "done" late, from a detached job straight to the tty: after $1
# seconds, if you still haven't responded. Then start the jobs named in the
# other arguments. Used when only background shells were left running (a
# server that never exits, say) and when a short turn's bell was held back.
late_done_job() {
  sleep "$1"
  shift
  still_waiting || return
  seq=
  [ "$BELL" = 1 ] && seq='\a'
  [ $progress = 1 ] && seq="$seq"'\033]9;4;4;100\007'
  [ -n "$seq" ] && [ -n "${tty:-}" ] && printf "$seq" >"$tty"
  if [ $os = windows ]; then winps flash; fi
  start_jobs "$@"
}

pick_mark() {
  case $1 in
    permission) mark=$MARK_PERMISSION ;;
    question) mark=$MARK_QUESTION ;;
    plan) mark=$MARK_PLAN ;;
    input) mark=$MARK_INPUT ;;
    error) mark=$MARK_ERROR ;;
    *) mark=$MARK_DONE ;;
  esac
}

case "$1" in
  wait)
    kind=${2:-done}
    pick_mark "$kind"

    # Whose wait this is, so `off tool` can tell its tool calls from others'.
    # For a permission prompt, `arm` noted the display name and the full tool
    # name (line 3). An older .req has no line 3: any later tool may clear it.
    owner= ptool= match_tool=
    if [ "$kind" = permission ] && [ -f "$state.req" ]; then
      {
        IFS= read -r owner
        IFS= read -r ptool
        IFS= read -r match_tool
      } <"$state.req"
      rm -f "$state.req"   # one arm belongs to the permission prompt that follows it
    fi
    [ -n "$owner" ] || owner=$agent_id
    label=$project
    [ -n "$ptool" ] && label="$project · $ptool"
    tool=
    case $kind in
      question|plan) tool=$tool_use_id ;;
      permission) tool=$match_tool ;;
    esac

    # bg was classified while reading Stop's background_tasks. Older Claude
    # Code omits the field, so bg stays empty and "done" shows at once.
    # Shells are timed; everything else in flight waits for Claude to resume.
    if [ "$kind" = done ]; then
      [ "$bg" = shell ] && [ "${BG_SHELL_MIN:-0}" -le 0 ] && bg=
    else
      bg=
    fi

    token="$$.${RANDOM:-0}"

    # Claude resumes by itself when background work finishes, and that turn's
    # Stop decides. Agents always finish; a shell may be a server that never
    # does, so after BG_SHELL_MIN "done" is signalled anyway.
    if [ -n "$bg" ]; then
      write_state busy
      if [ $bg = shell ]; then
        tty=
        [ $os != windows ] && claude_tty
        spawn late_done_job $((BG_SHELL_MIN * 60)) title nag
      fi
      exit 0
    fi

    # A short turn: you were probably watching it. Only the passive marks for
    # now (title, and the ring where Claude has no progress bar of its own);
    # the bell comes after SHORT_TURN_BELL_SEC if you still haven't responded.
    quiet=0
    if [ "$kind" = done ] && [ "${SHORT_TURN_SEC:-0}" -gt 0 ] && [ -f "$state.acted" ]; then
      since=
      IFS= read -r since <"$state.acted"
      case $since in
        ''|*[!0-9]*) ;;
        *) [ $(($(date +%s) - since)) -lt "$SHORT_TURN_SEC" ] && quiet=1 ;;
      esac
    fi

    write_state "$kind"

    seq=""
    [ "$BELL" = 1 ] && [ $quiet = 0 ] && seq='\u0007'
    [ $progress = 1 ] && seq="$seq"'\u001b]9;4;4;100\u0007'
    emit "$seq"

    tty=
    if [ $quiet = 1 ]; then
      start_jobs title
      if [ "${SHORT_TURN_BELL_SEC:-0}" -gt 0 ]; then
        [ $os != windows ] && [ -z "$tty" ] && claude_tty
        spawn late_done_job "$SHORT_TURN_BELL_SEC" nag
      fi
    else
      if [ $os = windows ]; then spawn winps flash; fi
      start_jobs title nag
    fi
    ;;
  off)
    # Only reached when this wait should end (see the checks at the top).
    rm -f "$state"
    # You answered Claude. (A tool call that ends a done/error/busy wait is
    # Claude resuming by itself, not you.)
    [ "${2:-}" = tool ] && case $w_kind in permission|question|plan|input) acted ;; esac
    [ $progress = 1 ] && emit '\u001b]9;4;0;0\u0007'
    ;;
  test)
    # Run by hand: what a wait looks like in this terminal, with your settings.
    pick_mark "${2:-done}"
    tty=/dev/tty
    echo "Switch to another app or tab: this tab gets marked in 5 s."
    sleep 5
    seq=
    [ "$BELL" = 1 ] && seq='\a'
    [ $progress = 1 ] && seq="$seq"'\033]9;4;4;100\007'
    [ -n "$seq" ] && printf "$seq" >"$tty"
    [ "$TITLE" = 1 ] && [ -n "$mark" ] && [ $os != windows ] && printf '\033]2;%s %s (test)\007' "$mark" "$project" >"$tty"
    if [ $os = windows ]; then winps flash </dev/null >/dev/null 2>&1 & fi
    printf 'Marked. Press Enter to clear. '
    read -r _ <"$tty"
    clear=
    [ $progress = 1 ] && clear='\033]9;4;0;0\007'
    printf "\033]2;\007$clear" >"$tty"
    ;;
esac
exit 0
