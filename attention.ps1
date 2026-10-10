# Windows helper for attention.sh.
#
#   attention.ps1 flash    flash the terminal's taskbar button until it gets focus
#
# Runs attached to the terminal's console; never use -WindowStyle Hidden here,
# it would hide the console window of a classic PowerShell/cmd terminal.
param([Parameter(Position = 0)][string]$Action)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

if ($Action -ne 'flash') { exit 0 }

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ClaudeAttention {
  [StructLayout(LayoutKind.Sequential)]
  struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
  [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO f);
  [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList(uint[] list, uint count);
  // FLASHW_TRAY (2) | FLASHW_TIMERNOFG (12): flash the taskbar button until the window is focused.
  public static void Flash(IntPtr h) {
    var f = new FLASHWINFO(); f.cbSize = (uint)Marshal.SizeOf(f); f.hwnd = h; f.dwFlags = 2 | 12;
    FlashWindowEx(ref f);
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

$h = Get-TerminalWindow
if ($h -ne [IntPtr]::Zero) { [ClaudeAttention]::Flash($h) }
