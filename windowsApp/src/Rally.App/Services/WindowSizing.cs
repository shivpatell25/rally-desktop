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
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct MinMax { public Point Reserved, MaxSize, MaxPosition, MinTrack, MaxTrack; }
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
        if (message == 0x24) // WM_GETMINMAXINFO; dimensions are physical pixels.
        {
            var info = Marshal.PtrToStructure<MinMax>(lParam); var scale = GetDpiForWindow(window) / 96d;
            info.MinTrack.X = (int)Math.Round(960 * scale); info.MinTrack.Y = (int)Math.Round(620 * scale);
            Marshal.StructureToPtr(info, lParam, false);
        }
        return result;
    }
    public void Dispose() => RemoveWindowSubclass(_window, _callback, new UIntPtr(1));
}
