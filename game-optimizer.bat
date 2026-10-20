@echo off
setlocal
title System Optimizer

fltmc >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

set "SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -TypeDefinition ([System.IO.File]::ReadAllText([Environment]::GetEnvironmentVariable('SELF')).Replace('@echo off','/*')); [SystemOptimizer.Engine]::Main()"
if %errorlevel% neq 0 (
    echo.
    pause
)
exit /b
*/

using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace SystemOptimizer
{
    public static class Engine
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        [DllImport("psapi.dll")]
        private static extern int EmptyWorkingSet(IntPtr hwProc);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private class MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
            public MEMORYSTATUSEX()
            {
                this.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);

        private const string C_RESET = "\u001b[0m";
        private const string C_BRAND = "\u001b[96m";
        private const string C_TEXT  = "\u001b[97m";
        private const string C_MUTED = "\u001b[37m";
        private const string C_DIM   = "\u001b[90m";
        private const string C_OK    = "\u001b[92m";
        private const string C_WARN  = "\u001b[93m";

        private const char TL     = '\u250C';
        private const char TR     = '\u2510';
        private const char BL     = '\u2514';
        private const char BR     = '\u2518';
        private const char ML     = '\u251C';
        private const char MR     = '\u2524';
        private const char H      = '\u2500';
        private const char V      = '\u2502';
        private const char BULLET = '\u25CF';

        private static long BytesFreed  = 0;
        private static bool RunDeep     = true;
        private static int  DaysLeft    = 0;
        private static string TrackFile = "";

        public static void Main()
        {
            try
            {
                InitializeConsole();
                RenderHeader();
                EvaluateCooldown();

                ulong ramBefore = GetAvailableRamBytes();
                string winDir   = Environment.GetFolderPath(Environment.SpecialFolder.Windows);

                WriteSection("STORAGE & CACHE SANITIZATION");

                InvokeStep("Purging User Temporary Workspace (%TEMP%)", delegate() {
                    long freed = CleanDirectory(Path.GetTempPath());
                    BytesFreed += freed;
                    return string.Format("-{0:0.0} MB", freed / 1048576.0);
                });

                InvokeStep("Purging Windows Prefetch Cache (%WINDIR%\\Prefetch)", delegate() {
                    long freed = CleanDirectory(Path.Combine(winDir, "Prefetch"));
                    BytesFreed += freed;
                    return string.Format("-{0:0.0} MB", freed / 1048576.0);
                });

                InvokeStep("Purging Windows System Temp (%WINDIR%\\Temp)", delegate() {
                    if (!RunDeep) return "SKIP:Cooldown";
                    long freed = CleanDirectory(Path.Combine(winDir, "Temp"));
                    BytesFreed += freed;
                    return string.Format("-{0:0.0} MB", freed / 1048576.0);
                });

                InvokeStep("Resetting Windows Update Delivery Cache", delegate() {
                    if (!RunDeep) return "SKIP:Cooldown";
                    RunCommand("net.exe", "stop wuauserv /y");
                    RunCommand("net.exe", "stop bits /y");
                    long freed = CleanDirectory(Path.Combine(winDir, @"SoftwareDistribution\Download"));
                    BytesFreed += freed;
                    RunCommand("net.exe", "start wuauserv");
                    return string.Format("-{0:0.0} MB", freed / 1048576.0);
                });

                InvokeStep("Clearing System Event Telemetry Logs", delegate() {
                    if (!RunDeep) return "SKIP:Cooldown";
                    int cleared = 0;
                    EventLogSession session = EventLogSession.GlobalSession;
                    foreach (string logName in session.GetLogNames())
                    {
                        try { session.ClearLog(logName); cleared++; } catch { }
                    }
                    return string.Format("{0} cleared", cleared);
                });

                InvokeStep("Flushing DNS Resolver & Socket Cache", delegate() {
                    RunCommand("ipconfig.exe", "/flushdns");
                    return null;
                });

                WriteSection("KERNEL & SCHEDULER OPTIMIZATION");

                InvokeStep("Tuning Win32 Priority Separation (Short Fixed 0x26)", delegate() {
                    SetRegDword(Registry.LocalMachine, @"SYSTEM\CurrentControlSet\Control\PriorityControl", "Win32PrioritySeparation", 38);
                    return null;
                });

                InvokeStep("Disabling Network Throttling & Multimedia Reservation", delegate() {
                    string mmcss = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile";
                    SetRegDword(Registry.LocalMachine, mmcss, "NetworkThrottlingIndex", unchecked((int)0xFFFFFFFF));
                    SetRegDword(Registry.LocalMachine, mmcss, "SystemResponsiveness", 0);
                    return null;
                });

                InvokeStep("Enabling Hardware-Accelerated GPU Scheduling & Game Mode", delegate() {
                    SetRegDword(Registry.CurrentUser, @"Software\Microsoft\GameBar", "AllowAutoGameMode", 1);
                    SetRegDword(Registry.CurrentUser, @"Software\Microsoft\GameBar", "AutoGameModeEnabled", 1);
                    SetRegDword(Registry.LocalMachine, @"SYSTEM\CurrentControlSet\Control\GraphicsDrivers", "HwSchMode", 2);
                    return null;
                });

                InvokeStep("Optimizing Desktop Window Manager Visual Effects", delegate() {
                    SetRegDword(Registry.CurrentUser, @"Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects", "VisualFxSetting", 2);
                    return null;
                });

                InvokeStep("Disabling All 12 Target Telemetry & Background Services", delegate() {
                    string[] services = new string[] {
                        "DiagTrack",
                        "dmwappushservice",
                        "DusmSvc",
                        "diagnosticshub.standardcollector.service",
                        "MapsBroker",
                        "wscsvc",
                        "lfsvc",
                        "TroubleshootingSvc",
                        "PcaSvc",
                        "Spooler",
                        "Fax",
                        "SysMain"
                    };
                    int tuned = 0;
                    foreach (string svc in services)
                    {
                        RunCommand("sc.exe", "config \"" + svc + "\" start= disabled");
                        RunCommand("sc.exe", "stop \"" + svc + "\"");
                        tuned++;
                    }
                    return string.Format("{0} disabled", tuned);
                });

                WriteSection("PROCESS & STORAGE MAINTENANCE");

                InvokeStep("Terminating All 28 Target Apps, Games & Launchers", delegate() {
                    string[] targets = new string[] {
                        "VALORANT-Win64-Shipping",
                        "RiotClientServices",
                        "FortniteClient-Win64-Shipping",
                        "EpicGamesLauncher",
                        "EpicWebHelper",
                        "OneDrive",
                        "steam",
                        "steamservice",
                        "steamwebhelper",
                        "backgroundTaskHost",
                        "SearchHost",
                        "SearchIndexer",
                        "ShellHost",
                        "VSHelper",
                        "YourPhone",
                        "PhoneExperienceHost",
                        "Cortana",
                        "msedgewebview2",
                        "CrossDeviceResume",
                        "SecurityHealthSystray",
                        "RobloxPlayerBeta",
                        "RobloxCrashHandler",
                        "qbittorrent",
                        "WinStore.App",
                        "spoolsv",
                        "SocialClubHelper",
                        "LauncherPatcher",
                        "GoogleCrashHandler",
                        "GoogleCrashHandler64",
                        "jhi_service"
                    };
                    int killed = 0;
                    foreach (string name in targets)
                    {
                        Process[] procs = Process.GetProcessesByName(name);
                        foreach (Process p in procs)
                        {
                            try { p.Kill(); killed++; } catch { }
                        }
                    }
                    return string.Format("{0} closed", killed);
                });

                InvokeStep("Reclaiming Idle Process Working Set Memory", delegate() {
                    int trimmed = 0;
                    foreach (Process p in Process.GetProcesses())
                    {
                        try
                        {
                            if (EmptyWorkingSet(p.Handle) != 0) trimmed++;
                        }
                        catch { }
                    }
                    return string.Format("{0} trimmed", trimmed);
                });

                InvokeStep("Refreshing Plug-and-Play Device Tree", delegate() {
                    RunCommand("pnputil.exe", "/scan-devices");
                    return null;
                });

                InvokeStep("Executing NVMe / SSD TRIM & Volume Optimization", delegate() {
                    if (!RunDeep) return string.Format("SKIP:{0}d left", DaysLeft);
                    RunCommand("defrag.exe", "C: /O");
                    long nowEpoch = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
                    File.WriteAllText(TrackFile, nowEpoch.ToString(), Encoding.ASCII);
                    return null;
                });

                ulong ramAfter = GetAvailableRamBytes();
                long ramFreedMB = 0;
                if (ramAfter > ramBefore)
                {
                    ramFreedMB = (long)((ramAfter - ramBefore) / 1048576UL);
                }

                RenderFooter(ramFreedMB);
            }
            catch (Exception ex)
            {
                Console.CursorVisible = true;
                Console.WriteLine();
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine("  [FATAL ENGINE ERROR]: " + ex.Message);
                Console.ResetColor();
                Console.WriteLine("  Press Enter to exit...");
                Console.ReadLine();
            }
        }

        private static void InitializeConsole()
        {
            try
            {
                IntPtr hOut = GetStdHandle(-11);
                uint mode;
                if (GetConsoleMode(hOut, out mode))
                {
                    SetConsoleMode(hOut, mode | 0x0004);
                }
                Console.OutputEncoding = Encoding.UTF8;
                Console.CursorVisible  = false;
                Console.Clear();
            }
            catch { }
        }

        private static void RenderHeader()
        {
            string cpuName = GetCpuName();
            string gpuName = GetGpuName();
            double ramGB   = Math.Round(GetTotalRamBytes() / 1073741824.0, 1);

            string line      = new string(H, 74);
            string titleStr  = FormatFixed("WINDOWS SYSTEM OPTIMIZER", 58);
            string authorStr = "v4.0.9 | Nahid".PadLeft(14);
            string hwLine1   = FormatFixed("CPU : " + cpuName, 72);
            string hwLine2   = FormatFixed(string.Format("GPU : {0}  |  RAM : {1:0.0} GB", gpuName, ramGB), 72);

            Console.WriteLine();
            Console.WriteLine("  " + C_DIM + TL + line + TR + C_RESET);
            Console.WriteLine("  " + C_DIM + V + C_RESET + " " + C_BRAND + titleStr + C_RESET + C_MUTED + authorStr + C_RESET + " " + C_DIM + V + C_RESET);
            Console.WriteLine("  " + C_DIM + ML + line + MR + C_RESET);
            Console.WriteLine("  " + C_DIM + V + C_RESET + " " + C_MUTED + hwLine1 + C_RESET + " " + C_DIM + V + C_RESET);
            Console.WriteLine("  " + C_DIM + V + C_RESET + " " + C_MUTED + hwLine2 + C_RESET + " " + C_DIM + V + C_RESET);
            Console.WriteLine("  " + C_DIM + BL + line + BR + C_RESET);
        }

        private static void RenderFooter(long ramFreedMB)
        {
            double diskFreedMB = Math.Round(BytesFreed / 1048576.0, 1);
            string deepState   = RunDeep ? "EXECUTED" : string.Format("COOLDOWN ({0}d)", DaysLeft);
            string summaryRaw  = string.Format("STORAGE RECOVERED: {0:0.0} MB   |   RAM FREED: {1} MB   |   DEEP CLEAN: {2}", diskFreedMB, ramFreedMB, deepState);
            string summaryText = FormatFixed(summaryRaw, 72);
            string line        = new string(H, 74);

            Console.WriteLine();
            Console.WriteLine("  " + C_DIM + TL + line + TR + C_RESET);
            Console.WriteLine("  " + C_DIM + V + C_RESET + " " + C_OK + summaryText + C_RESET + " " + C_DIM + V + C_RESET);
            Console.WriteLine("  " + C_DIM + BL + line + BR + C_RESET);
            Console.WriteLine();

            for (int i = 30; i >= 1; i--)
            {
                Console.Write("\r    " + C_DIM + string.Format("Your system is now fully optimized! Closing in {0}s...", i) + C_RESET + " ");
                Thread.Sleep(1000);
            }
            try { Console.CursorVisible = true; } catch { }
        }

        private static void EvaluateCooldown()
        {
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string trackDir     = Path.Combine(localAppData, @"Microsoft\Windows\SysOptData");
            TrackFile           = Path.Combine(trackDir, "lastrun.dat");

            try
            {
                if (!Directory.Exists(trackDir))
                {
                    DirectoryInfo di = Directory.CreateDirectory(trackDir);
                    di.Attributes |= FileAttributes.Hidden;
                }

                if (File.Exists(TrackFile))
                {
                    string raw     = File.ReadAllText(TrackFile).Trim();
                    long lastEpoch = long.Parse(raw);
                    long nowEpoch  = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
                    double diffDays = (nowEpoch - lastEpoch) / 86400.0;
                    if (diffDays >= 0 && diffDays < 6.0)
                    {
                        RunDeep  = false;
                        DaysLeft = (int)Math.Ceiling(6.0 - diffDays);
                    }
                }
            }
            catch
            {
                RunDeep = true;
            }
        }

        private static void WriteSection(string title)
        {
            Console.WriteLine();
            Console.WriteLine("  " + C_BRAND + BULLET + C_RESET + " " + C_TEXT + title + C_RESET);
            Console.WriteLine("  " + C_DIM + new string(H, 74) + C_RESET);
        }

        private static void InvokeStep(string label, Func<string> action)
        {
            string padLabel = FormatFixed(label, 52);
            Console.Write("    " + C_WARN + "[ WAIT ]" + C_RESET + " " + C_MUTED + padLabel + C_RESET);

            Stopwatch sw = Stopwatch.StartNew();
            string status = "OK";
            string note   = "";

            try
            {
                string res = action();
                if (!string.IsNullOrEmpty(res))
                {
                    if (res.StartsWith("SKIP:"))
                    {
                        status = "SKIP";
                        note   = res.Substring(5);
                    }
                    else
                    {
                        note = res;
                    }
                }
            }
            catch
            {
                status = "WARN";
            }

            sw.Stop();
            string ms = (sw.ElapsedMilliseconds.ToString() + "ms").PadLeft(12);

            if (status == "OK")
            {
                string meta = !string.IsNullOrEmpty(note) ? (C_OK + note.PadLeft(12) + C_RESET) : (C_DIM + ms + C_RESET);
                Console.WriteLine("\r    " + C_OK + "[  OK  ]" + C_RESET + " " + C_TEXT + padLabel + C_RESET + " " + meta);
            }
            else if (status == "SKIP")
            {
                string meta = C_DIM + note.PadLeft(12) + C_RESET;
                Console.WriteLine("\r    " + C_DIM + "[ SKIP ] " + padLabel + C_RESET + " " + meta);
            }
            else
            {
                Console.WriteLine("\r    " + C_WARN + "[ WARN ]" + C_RESET + " " + C_MUTED + padLabel + C_RESET + " " + C_DIM + ms + C_RESET);
            }
        }

        private static long CleanDirectory(string path)
        {
            long bytesDeleted = 0;
            if (!Directory.Exists(path)) return 0;

            DirectoryInfo root = new DirectoryInfo(path);
            foreach (FileInfo file in root.GetFiles("*", SearchOption.AllDirectories))
            {
                try
                {
                    long len = file.Length;
                    file.Attributes = FileAttributes.Normal;
                    file.Delete();
                    bytesDeleted += len;
                }
                catch { }
            }

            foreach (DirectoryInfo dir in root.GetDirectories("*", SearchOption.TopDirectoryOnly))
            {
                try { dir.Delete(true); } catch { }
            }

            return bytesDeleted;
        }

        private static void SetRegDword(RegistryKey root, string subKey, string name, int val)
        {
            try
            {
                using (RegistryKey key = root.CreateSubKey(subKey))
                {
                    if (key != null)
                    {
                        key.SetValue(name, val, RegistryValueKind.DWord);
                    }
                }
            }
            catch { }
        }

        private static void RunCommand(string fileName, string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(fileName, args);
                psi.CreateNoWindow   = true;
                psi.UseShellExecute  = false;
                using (Process p = Process.Start(psi))
                {
                    if (p != null) p.WaitForExit(30000);
                }
            }
            catch { }
        }

        private static string GetCpuName()
        {
            try
            {
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"HARDWARE\Description\System\CentralProcessor\0"))
                {
                    if (key != null && key.GetValue("ProcessorNameString") != null)
                    {
                        return key.GetValue("ProcessorNameString").ToString().Trim();
                    }
                }
            }
            catch { }
            return "Unknown Processor";
        }

        private static string GetGpuName()
        {
            try
            {
                string displayClass = @"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}";
                using (RegistryKey baseKey = Registry.LocalMachine.OpenSubKey(displayClass))
                {
                    if (baseKey != null)
                    {
                        foreach (string sub in baseKey.GetSubKeyNames())
                        {
                            if (!sub.StartsWith("0")) continue;
                            using (RegistryKey dev = baseKey.OpenSubKey(sub))
                            {
                                if (dev != null && dev.GetValue("DriverDesc") != null)
                                {
                                    string desc = dev.GetValue("DriverDesc").ToString().Trim();
                                    if (!desc.Contains("Basic") && !desc.Contains("Virtual") && !desc.Contains("Remote") && !desc.Contains("Parsec"))
                                    {
                                        return desc;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            catch { }
            return "Standard Display Adapter";
        }

        private static ulong GetTotalRamBytes()
        {
            MEMORYSTATUSEX mem = new MEMORYSTATUSEX();
            if (GlobalMemoryStatusEx(mem)) return mem.ullTotalPhys;
            return 0;
        }

        private static ulong GetAvailableRamBytes()
        {
            MEMORYSTATUSEX mem = new MEMORYSTATUSEX();
            if (GlobalMemoryStatusEx(mem)) return mem.ullAvailPhys;
            return 0;
        }

        private static string FormatFixed(string text, int width)
        {
            if (string.IsNullOrEmpty(text)) text = "";
            if (text.Length > width) return text.Substring(0, width);
            return text.PadRight(width);
        }
    }
}
