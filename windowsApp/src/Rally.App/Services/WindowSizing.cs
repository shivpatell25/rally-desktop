using System.Runtime.InteropServices;

namespace Rally.App.Services;

/// <summary>Keep controls usable while allowing normal native window resizing.</summary>
internal sealed class WindowSizing : IDisposable
{
    private delegate IntPtr SubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc callback, UIntPtr id, UIntPtr data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(IntPtr hwnd, SubclassProc callback, UIntPtr id);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct MinMax { public Point Reserved, MaxSize, MaxPosition, MinTrack, MaxTrack; }
    public bool Compact { get; set; }
    private readonly IntPtr _window;
    private readonly SubclassProc _callback;
    public WindowSizing(IntPtr window)
    {
        _window = window; _callback = OnMessage;
        SetWindowSubclass(window, _callback, new UIntPtr(1), UIntPtr.Zero);
    }
    private IntPtr OnMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
    {
        var result = DefSubclassProc(window, message, wParam, lParam);
        if (message == 0x24 && !Compact) // WM_GETMINMAXINFO; dimensions are physical pixels.
        {
            var info = Marshal.PtrToStructure<MinMax>(lParam); var scale = GetDpiForWindow(window) / 96d;
            var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() }; GetMonitorInfo(MonitorFromWindow(window, 2), ref monitor);
            info.MinTrack.X = Math.Min((int)Math.Round(720 * scale), Math.Max(480, monitor.Work.Right - monitor.Work.Left)); info.MinTrack.Y = Math.Min((int)Math.Round(500 * scale), Math.Max(360, monitor.Work.Bottom - monitor.Work.Top));
            Marshal.StructureToPtr(info, lParam, false);
        }
        return result;
    }
    public void Dispose() => RemoveWindowSubclass(_window, _callback, new UIntPtr(1));
}
