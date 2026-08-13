// Windows shell for David Claude HUD.
//
// The macOS shell is an NSPanel hosting a WKWebView. This is the same idea in
// Win32 terms: a borderless, always-on-top, tool-window form hosting WebView2,
// running the identical ui.html and the identical collect.py. Only the shell
// differs between the two platforms — the interface and the data layer are
// shared verbatim.
//
// NOT YET TESTED ON WINDOWS. It was written on a Mac with no Windows machine
// and no cross-compiler available, so it has never been built or run. Treat it
// as a starting point, not a release. See windows/README.md for the specific
// things that need verifying first.
//
// build:  dotnet build -c Release   (see HudShell.csproj)

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace ClaudeHud
{
    public class HudForm : Form
    {
        readonly WebView2 _web = new WebView2();
        readonly NotifyIcon _tray = new NotifyIcon();
        readonly System.Windows.Forms.Timer _tick = new System.Windows.Forms.Timer();
        readonly string _root;
        bool _busy;                 // a collector run is already in flight
        string _dockSide = "";
        bool _dockedOut = true;

        // A tool window stays out of Alt-Tab and the taskbar, which is what the
        // macOS accessory activation policy buys us there.
        const int WS_EX_TOOLWINDOW = 0x00000080;
        const int WS_EX_NOACTIVATE = 0x08000000;

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                // NOACTIVATE is the counterpart of the non-activating NSPanel:
                // clicking the HUD must not pull focus off the terminal you are
                // watching.
                cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return cp;
            }
        }

        public HudForm()
        {
            _root = AppDomain.CurrentDomain.BaseDirectory;

            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            Width = 360;
            Height = 620;
            var wa = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(wa.Right - Width - 20, wa.Top + 20);

            _web.Dock = DockStyle.Fill;
            Controls.Add(_web);

            _tray.Icon = SystemIcons.Application;
            _tray.Visible = true;
            _tray.Text = "Claude HUD";
            var menu = new ContextMenuStrip();
            menu.Items.Add("Show / Hide", null, (s, e) => Visible = !Visible);
            menu.Items.Add("Reset position", null, (s, e) => ResetPosition());
            menu.Items.Add("Reload", null, (s, e) => _web.CoreWebView2?.Reload());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, (s, e) => Application.Exit());
            _tray.ContextMenuStrip = menu;

            Load += async (s, e) => await Start();
        }

        async Task Start()
        {
            await _web.EnsureCoreWebView2Async();
            _web.CoreWebView2.Settings.AreDevToolsEnabled = false;
            _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            _web.DefaultBackgroundColor = Color.Transparent;
            _web.CoreWebView2.WebMessageReceived += OnMessage;
            _web.CoreWebView2.Navigate(new Uri(Path.Combine(_root, "ui.html")).ToString());

            _tick.Interval = 1500;
            _tick.Tick += async (s, e) => await Collect();
            _tick.Start();
        }

        // ---------------------------------------------------------------- data

        async Task Collect()
        {
            if (_busy || _web.CoreWebView2 == null) return;
            _busy = true;
            try
            {
                string json = await Task.Run(() => RunCollector());
                if (!string.IsNullOrWhiteSpace(json))
                    await _web.CoreWebView2.ExecuteScriptAsync("window.render(" + json + ")");
                // Machine figures the page can't get for itself. Windows has no
                // thermal state we can read, so it is reported as -1 and the
                // page hides that meter via its capability flags.
                await _web.CoreWebView2.ExecuteScriptAsync(
                    $"window.setMachine({Cpu():F1},{Ram():F1},0,-1)");
            }
            catch { /* a failed tick must never take the HUD down */ }
            finally { _busy = false; }
        }

        string RunCollector()
        {
            var psi = new ProcessStartInfo
            {
                FileName = "python",
                Arguments = "\"" + Path.Combine(_root, "collect.py") + "\"",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi);
            string outp = p.StandardOutput.ReadToEnd();
            p.WaitForExit(10000);
            return outp;
        }

        static PerformanceCounter _cpuCounter;
        static float Cpu()
        {
            _cpuCounter ??= new PerformanceCounter("Processor", "% Processor Time", "_Total");
            return _cpuCounter.NextValue();
        }

        static float Ram()
        {
            var mem = new Microsoft.VisualBasic.Devices.ComputerInfo();
            double total = mem.TotalPhysicalMemory;
            double free = mem.AvailablePhysicalMemory;
            return total > 0 ? (float)((total - free) / total * 100.0) : 0;
        }

        // ---------------------------------------------------------------- bridge

        async void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            JsonElement m;
            try { m = JsonDocument.Parse(e.WebMessageAsJson).RootElement; }
            catch { return; }
            string cmd = m.TryGetProperty("cmd", out var c) ? c.GetString() : null;

            switch (cmd)
            {
                case "geometry":
                    if (m.TryGetProperty("w", out var w) && m.TryGetProperty("h", out var h))
                    {
                        int nw = Math.Max(28, Math.Min(w.GetInt32(), 600));
                        int nh = Math.Max(34, Math.Min(h.GetInt32(),
                                          Screen.PrimaryScreen.WorkingArea.Height - 40));
                        // Keep the top-left pinned, as the macOS shell does.
                        Location = new Point(Location.X, Location.Y + (Height - nh));
                        Size = new Size(nw, nh);
                        ApplyDock(false);
                    }
                    break;

                case "drag":
                    // No performWindowDragWithEvent here; hand the drag to the
                    // window manager by faking a caption grab.
                    ReleaseCapture();
                    SendMessage(Handle, 0xA1 /* WM_NCLBUTTONDOWN */, 0x2 /* HTCAPTION */, 0);
                    break;

                case "dock":
                    _dockSide = m.TryGetProperty("side", out var sd) ? sd.GetString() : "";
                    _dockedOut = m.TryGetProperty("out", out var o) && o.GetBoolean();
                    if (_dockSide == "auto")
                        _dockSide = Location.X + Width / 2 >
                                    Screen.PrimaryScreen.WorkingArea.Width / 2 ? "right" : "left";
                    ApplyDock(true);
                    await _web.CoreWebView2.ExecuteScriptAsync(
                        $"window.__dockedSide('{_dockSide}')");
                    break;

                case "quit":
                    Application.Exit();
                    break;

                case "sound":
                    PlayAlert(m.TryGetProperty("which", out var wc) ? wc.GetString() : "needs-you");
                    break;

                case "badge":
                    int n = m.TryGetProperty("n", out var bn) ? bn.GetInt32() : 0;
                    _tray.Text = n > 0 ? $"Claude HUD — {n} new" : "Claude HUD";
                    break;

                case "killPid":
                    if (m.TryGetProperty("pid", out var kp))
                        try { Process.GetProcessById(kp.GetInt32()).Kill(); } catch { }
                    break;

                case "quitApp":
                    if (m.TryGetProperty("pid", out var qp))
                        try { Process.GetProcessById(qp.GetInt32()).CloseMainWindow(); } catch { }
                    break;

                // "focus" and "rename" are deliberately absent: Windows Terminal
                // exposes no per-tab addressing, so the page is told up front
                // that jumping isn't available rather than silently doing nothing.
            }
        }

        void PlayAlert(string which)
        {
            string file = Path.Combine(_root, "sounds",
                                       which == "done" ? "done.wav" : "needs-you.wav");
            try
            {
                if (File.Exists(file)) new System.Media.SoundPlayer(file).Play();
                else SystemSounds.Asterisk.Play();
            }
            catch { }
        }

        void ApplyDock(bool animate)
        {
            if (string.IsNullOrEmpty(_dockSide)) return;
            var wa = Screen.PrimaryScreen.WorkingArea;
            const int peek = 36, inset = 12;
            int x = _dockedOut
                ? (_dockSide == "right" ? wa.Right - Width - inset : wa.Left + inset)
                : (_dockSide == "right" ? wa.Right - peek : wa.Left - Width + peek);
            Location = new Point(x, Location.Y);
        }

        void ResetPosition()
        {
            _dockSide = "";
            var wa = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(wa.Right - Width - 20, wa.Top + 20);
            Visible = true;
        }

        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern int SendMessage(IntPtr h, int msg, int wp, int lp);

        [STAThread]
        public static void Main()
        {
            Application.EnableVisualStyles();
            Application.Run(new HudForm());
        }
    }
}
