// XMCP 反代工具 —— 原生启动器
// 作用：内嵌 xmcp.ico，作为任务栏/固定项的宿主 exe；启动同目录的 XMCP控制台.ps1，
//       等待其退出后再结束自身。窗口界面仍由 ps1(WinForms) 承载，本程序只负责拉起与身份绑定。
// 编译（.NET Framework 4.x，csc）：
//   csc /nologo /target:winexe /win32icon:xmcp.ico /out:XMCP.Relay.exe XMCP.Relay.Launcher.cs
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal static class Program
{
    // 与 XMCP控制台.ps1 里 SetCurrentProcessExplicitAppUserModelID 保持一致，
    // 让固定项、运行窗口归到同一任务栏分组。
    private const string AppUserModelId = "GeekMeng.XMcp.RelayTool.1";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [STAThread]
    private static int Main(string[] args)
    {
        try { SetCurrentProcessExplicitAppUserModelID(AppUserModelId); } catch { }

        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        // 文件名含中文，用 Unicode 转义书写，保证源码纯 ASCII、不受编译器默认代码页影响。
        string ps1 = Path.Combine(dir, "XMCP\u63A7\u5236\u53F0.ps1");

        if (!File.Exists(ps1))
        {
            MessageBox.Show(
                "XMCP console script not found. Keep this launcher exe in the same folder as the .ps1 file.",
                "XMCP Relay", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        string systemDir = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string psExe = Path.Combine(systemDir, @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(psExe)) { psExe = "powershell.exe"; }

        var psi = new ProcessStartInfo
        {
            FileName = psExe,
            WorkingDirectory = dir,
            UseShellExecute = false,
            CreateNoWindow = true,
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\""
        };

        // 透传附加参数（如 -AutoTray），留作后续扩展。
        if (args != null && args.Length > 0)
        {
            psi.Arguments += " " + string.Join(" ", args);
        }

        try
        {
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.HasExited ? p.ExitCode : 0;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "XMCP Relay", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
