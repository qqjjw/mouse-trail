# Mouse Trail MVP - close this terminal or press Ctrl+C to stop.
# Visual constants are intentionally kept here for easy personal customization.
$TrailColor = '#A855F7'
$TrailWidth = 4.0
$TrailLifetimeMs = 700

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal static class NativeMethods
{
    internal const int WS_EX_LAYERED = 0x00080000;
    internal const int WS_EX_TRANSPARENT = 0x00000020;
    internal const int WS_EX_TOOLWINDOW = 0x00000080;
    internal const int WS_EX_NOACTIVATE = 0x08000000;
    internal const int GWL_STYLE = -16;
    internal const long WS_CAPTION = 0x00C00000L;
    internal const long WS_THICKFRAME = 0x00040000L;
    internal const uint MONITOR_DEFAULTTONEAREST = 2;
    internal const byte AC_SRC_OVER = 0;
    internal const byte AC_SRC_ALPHA = 1;
    internal const int ULW_ALPHA = 2;

    [StructLayout(LayoutKind.Sequential)]
    internal struct POINT { internal int X; internal int Y; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SIZE { internal int Width; internal int Height; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT { internal int Left; internal int Top; internal int Right; internal int Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    internal struct MONITORINFO
    {
        internal int cbSize;
        internal RECT rcMonitor;
        internal RECT rcWork;
        internal uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct BLENDFUNCTION
    {
        internal byte BlendOp;
        internal byte BlendFlags;
        internal byte SourceConstantAlpha;
        internal byte AlphaFormat;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    internal static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    internal static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    internal static extern IntPtr GetWindowLong32(IntPtr hWnd, int index);

    internal static long GetWindowStyle(IntPtr hWnd)
    {
        return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, GWL_STYLE).ToInt64() : GetWindowLong32(hWnd, GWL_STYLE).ToInt64();
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UpdateLayeredWindow(
        IntPtr hWnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref POINT pptSrc, int crKey,
        ref BLENDFUNCTION pblend, int dwFlags);

    [DllImport("user32.dll")]
    internal static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    internal static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    internal static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    internal static extern IntPtr SelectObject(IntPtr hdc, IntPtr hObject);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DeleteObject(IntPtr hObject);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DeleteDC(IntPtr hdc);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}

internal sealed class TrailPoint
{
    internal PointF Position;
    internal long Time;
}

public sealed class MouseTrailForm : Form
{
    private readonly List<TrailPoint> points = new List<TrailPoint>(96);
    private readonly Timer timer = new Timer();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly Color trailColor;
    private readonly float trailWidth;
    private readonly int lifetimeMs;
    private Point lastCursor;
    private bool haveLastCursor;
    private PointF visualHead;
    private bool surfaceIsEmpty = true;
    private long lastFullscreenCheck;
    private bool fullscreen;
    private const int MarginPixels = 10;
    private const int MaxPoints = 192;

    public MouseTrailForm(string colorHtml, float width, int lifetime)
    {
        trailColor = ColorTranslator.FromHtml(colorHtml);
        trailWidth = width;
        lifetimeMs = lifetime;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Bounds = new Rectangle(-32000, -32000, 1, 1);

        timer.Interval = 16;
        timer.Tick += TickTrail;
        timer.Start();
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= NativeMethods.WS_EX_LAYERED | NativeMethods.WS_EX_TRANSPARENT |
                          NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        RenderTrail();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        timer.Stop();
        timer.Dispose();
        base.OnFormClosed(e);
    }

    private void TickTrail(object sender, EventArgs e)
    {
        long now = clock.ElapsedMilliseconds;

        if (now - lastFullscreenCheck >= 200)
        {
            lastFullscreenCheck = now;
            bool nextFullscreen = IsForegroundFullscreen();
            if (nextFullscreen != fullscreen)
            {
                fullscreen = nextFullscreen;
                points.Clear();
                haveLastCursor = false;
                if (fullscreen) Hide(); else ShowInactiveTopmost();
            }
        }

        if (fullscreen)
        {
            timer.Interval = 100;
            return;
        }

        NativeMethods.POINT nativePoint;
        if (!NativeMethods.GetCursorPos(out nativePoint)) return;
        Point cursor = new Point(nativePoint.X, nativePoint.Y);
        if (!haveLastCursor)
        {
            visualHead = cursor;
            lastCursor = cursor;
            haveLastCursor = true;
            AddPoint(visualHead, now);
        }
        else
        {
            lastCursor = cursor;

            // Follow the real cursor with a short, adaptive visual delay. Small hand
            // tremors are strongly damped, while fast movement remains responsive.
            float dx = cursor.X - visualHead.X;
            float dy = cursor.Y - visualHead.Y;
            float remaining = (float)Math.Sqrt(dx * dx + dy * dy);
            if (remaining >= 0.35f)
            {
                float response = Math.Min(0.82f, 0.34f + remaining / 90.0f);
                visualHead = new PointF(
                    visualHead.X + dx * response,
                    visualHead.Y + dy * response);

                if (points.Count == 0)
                    AddPoint(visualHead, now);
                else if (Distance(points[points.Count - 1].Position, visualHead) >= 0.65f)
                    AddDensifiedPoint(visualHead, now);
            }
        }

        while (points.Count > 0 && now - points[0].Time >= lifetimeMs)
            points.RemoveAt(0);

        if (points.Count > 0)
        {
            timer.Interval = 16;
            RenderTrail();
        }
        else
        {
            timer.Interval = 100;
            if (!surfaceIsEmpty)
                RenderTrail();
        }
    }

    private void AddPoint(PointF position, long now)
    {
        points.Add(new TrailPoint { Position = position, Time = now });
        if (points.Count > MaxPoints) points.RemoveRange(0, points.Count - MaxPoints);
        surfaceIsEmpty = false;
    }

    private void AddDensifiedPoint(PointF position, long now)
    {
        TrailPoint previous = points[points.Count - 1];
        PointF midpoint = new PointF(
            (previous.Position.X + position.X) * 0.5f,
            (previous.Position.Y + position.Y) * 0.5f);
        long midpointTime = previous.Time + (now - previous.Time) / 2;

        points.Add(new TrailPoint { Position = midpoint, Time = midpointTime });
        points.Add(new TrailPoint { Position = position, Time = now });
        if (points.Count > MaxPoints) points.RemoveRange(0, points.Count - MaxPoints);
        surfaceIsEmpty = false;
    }

    private void ShowInactiveTopmost()
    {
        Show();
        TopMost = true;
    }

    private static float Distance(Point a, Point b)
    {
        float dx = a.X - b.X;
        float dy = a.Y - b.Y;
        return (float)Math.Sqrt(dx * dx + dy * dy);
    }

    private static float Distance(PointF a, PointF b)
    {
        float dx = a.X - b.X;
        float dy = a.Y - b.Y;
        return (float)Math.Sqrt(dx * dx + dy * dy);
    }

    private bool IsForegroundFullscreen()
    {
        IntPtr foreground = NativeMethods.GetForegroundWindow();
        if (foreground == IntPtr.Zero || foreground == Handle) return false;

        NativeMethods.RECT windowRect;
        if (!NativeMethods.GetWindowRect(foreground, out windowRect)) return false;

        IntPtr monitor = NativeMethods.MonitorFromWindow(foreground, NativeMethods.MONITOR_DEFAULTTONEAREST);
        NativeMethods.MONITORINFO info = new NativeMethods.MONITORINFO();
        info.cbSize = Marshal.SizeOf(typeof(NativeMethods.MONITORINFO));
        if (!NativeMethods.GetMonitorInfo(monitor, ref info)) return false;

        const int tolerance = 2;
        bool fillsMonitor =
            windowRect.Left <= info.rcMonitor.Left + tolerance &&
            windowRect.Top <= info.rcMonitor.Top + tolerance &&
            windowRect.Right >= info.rcMonitor.Right - tolerance &&
            windowRect.Bottom >= info.rcMonitor.Bottom - tolerance;

        if (!fillsMonitor) return false;

        long style = NativeMethods.GetWindowStyle(foreground);
        bool borderless = (style & (NativeMethods.WS_CAPTION | NativeMethods.WS_THICKFRAME)) == 0;
        // Requiring a borderless window keeps an ordinary maximized window visible
        // while hiding browser F11 and similar presentation-style fullscreen modes.
        return borderless;
    }

    private void RenderTrail()
    {
        Rectangle bounds = CalculateBounds();

        using (Bitmap bitmap = new Bitmap(Math.Max(1, bounds.Width), Math.Max(1, bounds.Height), PixelFormat.Format32bppPArgb))
        {
            if (points.Count >= 2)
            {
                using (Graphics graphics = Graphics.FromImage(bitmap))
                {
                    graphics.SmoothingMode = SmoothingMode.AntiAlias;
                    graphics.CompositingMode = CompositingMode.SourceOver;
                    graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    DrawSegments(graphics, bounds.Location);
                }
            }
            UpdateLayeredBitmap(bitmap, bounds.Location);
        }
        surfaceIsEmpty = points.Count == 0;
    }

    private Rectangle CalculateBounds()
    {
        if (points.Count == 0) return new Rectangle(-32000, -32000, 1, 1);

        float minX = points[0].Position.X;
        float maxX = minX;
        float minY = points[0].Position.Y;
        float maxY = minY;
        for (int i = 1; i < points.Count; i++)
        {
            PointF p = points[i].Position;
            minX = Math.Min(minX, p.X); maxX = Math.Max(maxX, p.X);
            minY = Math.Min(minY, p.Y); maxY = Math.Max(maxY, p.Y);
        }

        int left = (int)Math.Floor(minX) - MarginPixels;
        int top = (int)Math.Floor(minY) - MarginPixels;
        int right = (int)Math.Ceiling(maxX) + MarginPixels;
        int bottom = (int)Math.Ceiling(maxY) + MarginPixels;
        return Rectangle.FromLTRB(left, top, Math.Max(left + 1, right), Math.Max(top + 1, bottom));
    }

    private void DrawSegments(Graphics graphics, Point origin)
    {
        long now = clock.ElapsedMilliseconds;

        if (points.Count == 2)
        {
            TrailPoint first = points[0];
            TrailPoint second = points[1];
            float age = now - ((first.Time + second.Time) / 2.0f);
            float opacity = Math.Max(0.0f, Math.Min(1.0f, 1.0f - age / lifetimeMs));
            int alpha = (int)(255 * opacity * opacity);
            if (alpha <= 0) return;
            using (Pen pen = new Pen(Color.FromArgb(alpha, trailColor), trailWidth))
            {
                pen.StartCap = LineCap.Flat;
                pen.EndCap = LineCap.Flat;
                graphics.DrawLine(pen,
                    LocalPoint(first.Position, origin),
                    LocalPoint(second.Position, origin));
            }
            return;
        }

        // Join adjacent midpoints with quadratic Bezier curves. Unlike a cardinal
        // spline, this corner-cutting curve stays inside the sampled path and cannot
        // overshoot or wobble when new cursor samples arrive.
        for (int i = 1; i < points.Count - 1; i++)
        {
            TrailPoint previous = points[i - 1];
            TrailPoint current = points[i];
            TrailPoint next = points[i + 1];
            float age = now - current.Time;
            float opacity = Math.Max(0.0f, Math.Min(1.0f, 1.0f - age / lifetimeMs));
            int alpha = (int)(255 * opacity * opacity);
            if (alpha <= 0) continue;

            PointF start = i == 1
                ? previous.Position
                : Midpoint(previous.Position, current.Position);
            PointF end = i == points.Count - 2
                ? next.Position
                : Midpoint(current.Position, next.Position);
            PointF control1 = new PointF(
                start.X + (current.Position.X - start.X) * (2.0f / 3.0f),
                start.Y + (current.Position.Y - start.Y) * (2.0f / 3.0f));
            PointF control2 = new PointF(
                end.X + (current.Position.X - end.X) * (2.0f / 3.0f),
                end.Y + (current.Position.Y - end.Y) * (2.0f / 3.0f));

            using (GraphicsPath path = new GraphicsPath())
            using (Pen pen = new Pen(Color.FromArgb(alpha, trailColor), trailWidth))
            {
                pen.StartCap = LineCap.Flat;
                pen.EndCap = LineCap.Flat;
                path.AddBezier(
                    LocalPoint(start, origin),
                    LocalPoint(control1, origin),
                    LocalPoint(control2, origin),
                    LocalPoint(end, origin));
                graphics.DrawPath(pen, path);
            }
        }
    }

    private static PointF Midpoint(PointF a, PointF b)
    {
        return new PointF((a.X + b.X) * 0.5f, (a.Y + b.Y) * 0.5f);
    }

    private static PointF LocalPoint(PointF point, Point origin)
    {
        return new PointF(point.X - origin.X, point.Y - origin.Y);
    }

    private void UpdateLayeredBitmap(Bitmap bitmap, Point screenPosition)
    {
        IntPtr screenDc = NativeMethods.GetDC(IntPtr.Zero);
        IntPtr memoryDc = NativeMethods.CreateCompatibleDC(screenDc);
        IntPtr bitmapHandle = IntPtr.Zero;
        IntPtr previousObject = IntPtr.Zero;

        try
        {
            bitmapHandle = bitmap.GetHbitmap(Color.FromArgb(0));
            previousObject = NativeMethods.SelectObject(memoryDc, bitmapHandle);
            NativeMethods.POINT destination = new NativeMethods.POINT { X = screenPosition.X, Y = screenPosition.Y };
            NativeMethods.SIZE size = new NativeMethods.SIZE { Width = bitmap.Width, Height = bitmap.Height };
            NativeMethods.POINT source = new NativeMethods.POINT { X = 0, Y = 0 };
            NativeMethods.BLENDFUNCTION blend = new NativeMethods.BLENDFUNCTION
            {
                BlendOp = NativeMethods.AC_SRC_OVER,
                BlendFlags = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = NativeMethods.AC_SRC_ALPHA
            };
            NativeMethods.UpdateLayeredWindow(Handle, screenDc, ref destination, ref size,
                memoryDc, ref source, 0, ref blend, NativeMethods.ULW_ALPHA);
        }
        finally
        {
            if (previousObject != IntPtr.Zero) NativeMethods.SelectObject(memoryDc, previousObject);
            if (bitmapHandle != IntPtr.Zero) NativeMethods.DeleteObject(bitmapHandle);
            NativeMethods.DeleteDC(memoryDc);
            NativeMethods.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }
}

public static class MouseTrailProgram
{
    [STAThread]
    public static void Run(string colorHtml, float width, int lifetimeMs)
    {
        // Per-monitor-v2 DPI awareness. Failure simply means Windows already chose a mode.
        NativeMethods.SetProcessDpiAwarenessContext(new IntPtr(-4));
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MouseTrailForm(colorHtml, width, lifetimeMs));
    }
}
'@

try {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # Windows PowerShell uses the built-in .NET Framework references directly.
        Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @(
            'System.Windows.Forms.dll',
            'System.Drawing.dll'
        )
    }
    else {
        # PowerShell 7 uses its bundled references, so no separate SDK is required.
        $frameworkReferences = @(
            Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName
            Join-Path $PSHOME 'System.Windows.Forms.dll'
            Join-Path $PSHOME 'System.Windows.Forms.Primitives.dll'
            Join-Path $PSHOME 'System.Drawing.Common.dll'
            Join-Path $PSHOME 'System.Private.Windows.Core.dll'
            Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll'
            Join-Path $PSHOME 'System.Windows.Extensions.dll'
        )
        Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies $frameworkReferences
    }

    Write-Host 'Mouse Trail is running.' -ForegroundColor Magenta
    Write-Host 'Close this window or press Ctrl+C to stop.'
    [MouseTrailProgram]::Run($TrailColor, [single]$TrailWidth, $TrailLifetimeMs)
}
catch {
    Write-Error $_
    Write-Host 'Press Enter to close.'
    [void](Read-Host)
    exit 1
}
