# Install the Claude Code attention hooks for the current user (Windows).
#
#   powershell -ExecutionPolicy Bypass -File install.ps1              install or upgrade
#   powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun      print the resulting settings.json
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   remove our hooks and scripts
#
# Your other settings and hooks are left alone: our hook groups are appended to
# each event, and hooks are recognised as ours by "hooks/attention.sh" in
# their command, so re-running never duplicates them.
param([switch]$Uninstall, [switch]$DryRun)
$ErrorActionPreference = 'Stop'

$Src = $PSScriptRoot
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$HooksDir = Join-Path $ClaudeDir 'hooks'
$Settings = Join-Path $ClaudeDir 'settings.json'
$Utf8 = New-Object Text.UTF8Encoding $false

function Test-Ours($hook) { [string]$hook.command -match 'hooks/attention\.sh' }
function Test-HasOurs($group) { [bool](@($group.hooks) | Where-Object { Test-Ours $_ }) }
function Has($obj, $name) { $null -ne $obj.PSObject.Properties[$name] }

if ($Uninstall -and -not (Test-Path $Settings)) { Write-Host "Nothing to do: $Settings does not exist."; exit 0 }

$s = $null
if (Test-Path $Settings) {
  $raw = Get-Content $Settings -Raw -Encoding UTF8   # $null for an empty file
  if ($raw -and $raw.Trim()) { $s = $raw | ConvertFrom-Json }
}
if ($null -eq $s) { $s = [pscustomobject]@{} }

# --- remove our hook objects; drop groups/events/hooks only if that emptied them
if ((Has $s 'hooks') -and $s.hooks -is [pscustomobject]) {
  foreach ($ev in @($s.hooks.PSObject.Properties.Name)) {
    $groups = @($s.hooks.$ev)
    if (-not ($groups | Where-Object { Test-HasOurs $_ })) { continue }
    $kept = @()
    foreach ($g in $groups) {
      if (Test-HasOurs $g) {
        $g.hooks = @(@($g.hooks) | Where-Object { -not (Test-Ours $_) })
        if ($g.hooks.Count -eq 0) { continue }
      }
      $kept += $g
    }
    if ($kept.Count -gt 0) { $s.hooks.$ev = $kept } else { $s.hooks.PSObject.Properties.Remove($ev) }
  }
  if (@($s.hooks.PSObject.Properties).Count -eq 0) { $s.PSObject.Properties.Remove('hooks') }
}

# --- append ours
if (-not $Uninstall) {
  $ours = (Get-Content (Join-Path $Src 'attention-hooks.json') -Raw -Encoding UTF8 | ConvertFrom-Json).hooks
  if (-not (Has $s 'hooks')) { $s | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
  foreach ($p in $ours.PSObject.Properties) {
    if (Has $s.hooks $p.Name) {
      $s.hooks.($p.Name) = @(@($s.hooks.($p.Name)) + @($p.Value))
    } else {
      $s.hooks | Add-Member -NotePropertyName $p.Name -NotePropertyValue @($p.Value)
    }
  }
}

$json = ConvertTo-Json -InputObject $s -Depth 32
if ($DryRun) { $json; exit 0 }

# --- warnings
function Warn($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
if (-not $Uninstall) {
  $others = @()
  foreach ($ev in 'Stop', 'Notification', 'PreToolUse') {
    if (Has $s.hooks $ev) {
      $others += @($s.hooks.$ev) | ForEach-Object { @($_.hooks) } | Where-Object {
        -not (Test-Ours $_) -and [string]$_.command -match 'osascript|terminal-notifier|afplay|(^|[^a-z])say |BurntToast|ToastNotification|notify-send|\\a|\\007'
      } | ForEach-Object { $_.command }
    }
  }
  if ($others.Count) { Warn 'Other hooks already look like notifiers; you may get double alerts:'; $others | Sort-Object -Unique | ForEach-Object { Write-Host "      $_" } }
  if ((Has $s 'disableAllHooks') -and $s.disableAllHooks) { Warn '"disableAllHooks" is true in settings.json, so no hooks run.' }
  $bash = $env:CLAUDE_CODE_GIT_BASH_PATH
  if (-not $bash) { $bash = (Get-Command bash.exe -ErrorAction SilentlyContinue).Source }
  if (-not $bash -and (Test-Path "$env:ProgramFiles\Git\bin\bash.exe")) { $bash = "$env:ProgramFiles\Git\bin\bash.exe" }
  if (-not $bash) { Warn 'Git Bash not found. Claude Code on Windows runs hooks with it: install Git for Windows.' }
}

# --- write
New-Item -ItemType Directory -Force -Path $HooksDir | Out-Null
$backup = $null
if (Test-Path $Settings) {
  $backup = "$Settings.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item $Settings $backup
}
[IO.File]::WriteAllText($Settings, $json + "`n", $Utf8)

# Copy with LF line endings: sh chokes on CRLF from a Windows checkout.
function Copy-Lf($name) {
  $text = [IO.File]::ReadAllText((Join-Path $Src $name)) -replace "`r`n", "`n"
  [IO.File]::WriteAllText((Join-Path $HooksDir $name), $text, $Utf8)
}

if (-not $Uninstall) {
  Copy-Lf 'attention.sh'
  Copy-Item (Join-Path $Src 'attention.ps1') $HooksDir -Force
  if (-not (Test-Path (Join-Path $HooksDir 'attention.conf'))) { Copy-Lf 'attention.conf' }
  Write-Host 'Installed Claude Code attention hooks.'
  Write-Host "  script:   $HooksDir\attention.sh"
  Write-Host "  settings: $HooksDir\attention.conf"
  Write-Host "  hooks:    $Settings$(if ($backup) { " (backup: $backup)" })"
  Write-Host ''
  Write-Host 'New Claude Code sessions pick it up; running ones need a restart.'
  Write-Host ''
  Write-Host 'Optional, Windows Terminal: add "bellStyle": ["window", "taskbar"] to profiles.defaults.'
} else {
  foreach ($f in 'attention.sh', 'attention.ps1', 'attention.mute') { Remove-Item (Join-Path $HooksDir $f) -ErrorAction SilentlyContinue }
  Remove-Item (Join-Path $env:TEMP 'claude-attention-*') -ErrorAction SilentlyContinue   # attention.sh's state files
  Write-Host "Removed the attention hooks from $Settings$(if ($backup) { " (backup: $backup)" })."
  if (Test-Path (Join-Path $HooksDir 'attention.conf')) { Write-Host "Kept your $HooksDir\attention.conf; delete it if you don't need it." }
}
