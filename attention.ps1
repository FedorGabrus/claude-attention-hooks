# Windows helper for attention.sh (Windows PowerShell 5.1: WinRT toasts need it).
#
#   attention.ps1 notify -Body text -Project name -Tag <session> -Sound 0|1
#                        -AwaySec 120 -State <file> -Token <token> [-Always]
#       show a toast if the wait (line 1 of -State is -Token) is still on and
#       you're not looking: the terminal window in front and you were active
#       recently. Exit 0 if a toast was shown, 1 otherwise.
#   attention.ps1 flash                   flash the terminal's taskbar button
#                                         until it gets focus
#   attention.ps1 clear -Tag <session>    remove that session's toast
#
# Runs attached to the terminal's console; never use -WindowStyle Hidden here,
# it would hide the console window of a classic PowerShell/cmd terminal.
param(
  [Parameter(Position = 0)][string]$Action,
  [string]$Body = '',
  [string]$Project = '',
  [string]$Tag = 'default',
  [int]$Sound = 0,
  [int]$AwaySec = 120,
  [string]$State = '',
  [string]$Token = '',
  [switch]$Always
)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$Group = 'claude-attention'
$Tag = $Tag.Substring(0, [Math]::Min(64, $Tag.Length))

# Line 1 of the state file holds the token of the wait that's still on.
function Test-Waiting { $State -and (Get-Content -LiteralPath $State -TotalCount 1) -eq $Token }

if ($Action -eq 'notify' -and -not (Test-Waiting)) { exit 1 }

# Compiling this takes a moment, so only the actions that use it pay for it.
if ($Action -eq 'flash' -or ($Action -eq 'notify' -and -not $Always)) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ClaudeAttention {
  [StructLayout(LayoutKind.Sequential)]
  struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
  [StructLayout(LayoutKind.Sequential)]
  struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO f);
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO l);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList(uint[] list, uint count);
  // FLASHW_TRAY (2) | FLASHW_TIMERNOFG (12): flash the taskbar button until the window is focused.
  public static void Flash(IntPtr h) {
    var f = new FLASHWINFO(); f.cbSize = (uint)Marshal.SizeOf(f); f.hwnd = h; f.dwFlags = 2 | 12;
    FlashWindowEx(ref f);
  }
  public static uint IdleMs() {
    var l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(l); GetLastInputInfo(ref l);
    return unchecked((uint)Environment.TickCount - l.dwTime);
  }
  // PIDs of every process attached to this console.
  public static uint[] ConsolePids() {
    var a = new uint[64];
    var n = GetConsoleProcessList(a, (uint)a.Length);
    if (n > a.Length) { a = new uint[n]; n = GetConsoleProcessList(a, n); }
    if (n > a.Length) n = (uint)a.Length;
    Array.Resize(ref a, (int)n);
    return a;
  }
}
'@
}

# Walk up to the first ancestor that owns a window: WindowsTerminal.exe, the
# classic console host's shell, Code.exe, ... Start from every process on this
# console (Claude itself, your shell), not just from us: attention.sh runs us
# in the background, so by now the hook that started us has usually exited and
# our own chain of parents is broken.
function Get-TerminalWindow {
  # One WMI query for the whole process table instead of one per ancestor.
  $parent = @{}
  Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId | ForEach-Object { $parent[[int]$_.ProcessId] = [int]$_.ParentProcessId }
  $starts = @([ClaudeAttention]::ConsolePids() | Where-Object { $_ -ne $PID }) + @($parent[$PID])
  foreach ($id in $starts) {
    for ($i = 0; $i -lt 20 -and $id; $i++) {
      $p = Get-Process -Id $id
      if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { return $p.MainWindowHandle }
      $id = $parent[[int]$id]
    }
  }
  return [IntPtr]::Zero
}

if ($Action -in 'notify', 'clear') {
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
}

switch ($Action) {
  'notify' {
    if (-not $Always) {
      $h = Get-TerminalWindow
      $front = $h -ne [IntPtr]::Zero -and [ClaudeAttention]::GetForegroundWindow() -eq $h
      $active = [ClaudeAttention]::IdleMs() -lt ($AwaySec * 1000)
      if ($front -and $active) { exit 1 }
    }

    $title = if ($Project) { "Claude Code - $Project" } else { 'Claude Code' }
    $audio = if ($Sound -eq 1) { '<audio src="ms-winsoundevent:Notification.Default"/>' } else { '<audio silent="true"/>' }
    $xml = "<toast><visual><binding template=`"ToastGeneric`"><text>$([Security.SecurityElement]::Escape($title))</text><text>$([Security.SecurityElement]::Escape($Body))</text></binding></visual>$audio</toast>"

    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
    # Same tag + group replaces this session's previous toast instead of stacking.
    $toast.Tag = $Tag
    $toast.Group = $Group
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)

    # Answered while we were getting here: `off` has already run its clear,
    # so take the toast back ourselves.
    if (-not (Test-Waiting)) {
      [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($Tag, $Group, $AppId)
      exit 1
    }
    exit 0
  }
  'flash' {
    $h = Get-TerminalWindow
    if ($h -ne [IntPtr]::Zero) { [ClaudeAttention]::Flash($h) }
  }
  'clear' {
    [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($Tag, $Group, $AppId)
  }
}
