#!/bin/sh
# Install the Claude Code attention hooks for the current user (macOS / Linux /
# Git Bash).
#
#   ./install.sh               install or upgrade
#   ./install.sh --dry-run     print the resulting settings.json, change nothing
#   ./install.sh --uninstall   remove our hooks and scripts
#
# Your other settings and hooks are left alone: our hook groups are appended to
# each event, and hooks are recognised as ours by "hooks/attention.sh" in
# their command, so re-running never duplicates them.
set -eu

src=$(cd "$(dirname "$0")" && pwd)
claude_dir="$HOME/.claude"
hooks_dir="$claude_dir/hooks"
settings="$claude_dir/settings.json"
ours_re='hooks/attention\.sh'   # how our hooks are recognised in settings.json

mode=install
dry=0
backup=""
for arg in "$@"; do
  case $arg in
    --uninstall) mode=uninstall ;;
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

tmp=$(mktemp "${TMPDIR:-/tmp}/attention-settings.XXXXXX")
trap 'rm -f "$tmp"' EXIT

current='{}'
[ -s "$settings" ] && current=$(cat "$settings")

# --- merge ------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$current" | jq --arg mode "$mode" --arg re "$ours_re" --slurpfile ours "$src/attention-hooks.json" '
    def ours: (.command? // "") | test($re);
    # Remove our hook objects; drop groups/events/hooks only if that emptied them.
    def strip:
      if (.hooks | type) == "object" then
        .hooks |= with_entries(
          if any(.value[]?; any(.hooks[]?; ours)) then
            .value |= map(
              if any(.hooks[]?; ours)
              then (.hooks |= map(select(ours | not))) | select(.hooks | length > 0)
              else . end)
            | select(.value | length > 0)
          else . end)
        | if .hooks == {} then del(.hooks) else . end
      else . end;
    strip
    | if $mode == "install" then
        .hooks = (reduce ($ours[0].hooks | to_entries[]) as $e
                    (.hooks // {}; .[$e.key] = ((.[$e.key] // []) + $e.value)))
      else . end
  ' >"$tmp"
elif command -v python3 >/dev/null 2>&1; then
  printf '%s' "$current" | python3 -c '
import json, re, sys
mode, ours_path, ours_re = sys.argv[1:4]
s = json.load(sys.stdin)
is_ours = lambda h: re.search(ours_re, h.get("command") or "") is not None
hooks = s.get("hooks")
if isinstance(hooks, dict):
    for event in list(hooks):
        groups = hooks[event]
        if not any(is_ours(h) for g in groups for h in g.get("hooks", [])):
            continue
        kept = []
        for g in groups:
            if any(is_ours(h) for h in g.get("hooks", [])):
                g["hooks"] = [h for h in g["hooks"] if not is_ours(h)]
                if not g["hooks"]:
                    continue
            kept.append(g)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        del s["hooks"]
if mode == "install":
    with open(ours_path) as f:
        ours = json.load(f)["hooks"]
    h = s.setdefault("hooks", {})
    for event, groups in ours.items():
        h[event] = h.get(event, []) + groups
json.dump(s, sys.stdout, indent=2, ensure_ascii=False)
print()
' "$mode" "$src/attention-hooks.json" "$ours_re" >"$tmp"
else
  echo "Need jq or python3 to edit $settings." >&2
  exit 1
fi

if [ $dry = 1 ]; then
  cat "$tmp"
  exit 0
fi

# --- warnings ---------------------------------------------------------------
warn() { printf '  ! %s\n' "$*"; }
if [ $mode = install ] && command -v jq >/dev/null 2>&1; then
  others=$(jq -r --arg re "$ours_re" '
    [.hooks // {} | to_entries[] | select(.key | test("^(Stop|Notification|PreToolUse)$"))
     | .value[]?.hooks[]?.command? // empty
     | select(test($re) | not)
     | select(test("osascript|terminal-notifier|afplay|(^|[^a-z])say |BurntToast|ToastNotification|notify-send|\\\\a|\\\\007"))]
    | unique[]' "$tmp")
  [ -n "$others" ] && { warn "Other hooks already look like notifiers; you may get double alerts:"; printf '      %s\n' "$others"; }
  [ "$(jq -r '.disableAllHooks // false' "$tmp")" = true ] && warn '"disableAllHooks" is true in settings.json, so no hooks run.'
fi

# --- write ------------------------------------------------------------------
if [ $mode = uninstall ] && [ ! -f "$settings" ]; then
  echo "Nothing to do: $settings does not exist."
  exit 0
fi
mkdir -p "$hooks_dir"
if [ -f "$settings" ]; then
  backup="$settings.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$settings" "$backup"
  cat "$tmp" >"$settings"   # keeps the file's permissions
else
  cp "$tmp" "$settings"
fi

if [ $mode = install ]; then
  cp "$src/attention.sh" "$src/attention.ps1" "$hooks_dir/"
  [ -f "$hooks_dir/attention.conf" ] || cp "$src/attention.conf" "$hooks_dir/"
  echo "Installed Claude Code attention hooks."
  echo "  script:   $hooks_dir/attention.sh"
  echo "  settings: $hooks_dir/attention.conf"
  echo "  hooks:    $settings${backup:+ (backup: $backup)}"
  echo
  echo "New Claude Code sessions pick it up; running ones need a restart."
  case "$(uname -s)" in
    Darwin)
      cat <<'TIPS'

One-time setup on macOS:
  - Ghostty/iTerm2/kitty: Claude Code sends its own pop-ups there. For markers only,
    run /config in Claude Code and set Notifications to disabled.
  - System Settings > Notifications > your terminal (Ghostty/iTerm2): allow, with
    Badges on, so the dock icon keeps a badge until you come back. Set the alert
    style to None if you only want the badge.
  - Terminal.app: Settings > Profiles > Advanced > Bell: tick "Badge app icon" and
    "Bounce app icon", untick "Audible bell" (or it beeps at every turn end).
  - iTerm2: Settings > Profiles > Terminal: "Silence bell", "Show bell icon in tabs".
  - VS Code: "terminal.integrated.enableVisualBell": true, "accessibility.signals.terminalBell": {"sound": "off"}.
TIPS
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo
      echo "Windows Terminal: optionally set \"bellStyle\": [\"window\", \"taskbar\"] in profiles.defaults."
      ;;
  esac
else
  rm -f "$hooks_dir/attention.sh" "$hooks_dir/attention.ps1" "$hooks_dir/attention.mute"
  rm -f "${TMPDIR:-${TEMP:-/tmp}}"/claude-attention-* 2>/dev/null || true   # attention.sh's state files
  echo "Removed the attention hooks from $settings${backup:+ (backup: $backup)}."
  if [ -f "$hooks_dir/attention.conf" ]; then
    echo "Kept your $hooks_dir/attention.conf; delete it if you don't need it."
  fi
fi
exit 0
