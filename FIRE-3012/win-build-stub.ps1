$dir = Join-Path $env:USERPROFILE '.rogue-spike-3012\bin'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$src = @'
using System;
using System.IO;
using System.Management;
public static class Program {
  public static int Main(string[] args) {
    string input = "";
    try { input = Console.In.ReadToEnd(); } catch {}
    string parent = "";
    try {
      int pid = System.Diagnostics.Process.GetCurrentProcess().Id;
      using (var s = new ManagementObjectSearcher("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" + pid)) {
        foreach (ManagementObject o in s.Get()) {
          uint ppid = (uint)o["ParentProcessId"];
          using (var s2 = new ManagementObjectSearcher("SELECT CommandLine FROM Win32_Process WHERE ProcessId=" + ppid)) {
            foreach (ManagementObject p in s2.Get()) parent = (string)p["CommandLine"] ?? "";
          }
        }
      }
    } catch {}
    if (parent.Length > 220) parent = parent.Substring(0, 220);
    string log = Path.Combine(Environment.GetEnvironmentVariable("USERPROFILE"), ".rogue-spike-3012\\calls.log");
    File.AppendAllText(log, "args=[" + string.Join("][", args) + "] stdin_bytes=" + input.Length + " parent=" + parent.Replace("\r"," ").Replace("\n"," ") + Environment.NewLine);
    Console.Out.Write("{}");
    return 0;
  }
}
'@
Add-Type -TypeDefinition $src -ReferencedAssemblies System.Management -OutputAssembly (Join-Path $dir 'rogue-hook.exe') -OutputType ConsoleApplication
'{"a":1}' | & (Join-Path $dir 'rogue-hook.exe') test X
Get-Content (Join-Path $env:USERPROFILE '.rogue-spike-3012\calls.log')
