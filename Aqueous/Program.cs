using System;
using System.Runtime.InteropServices;
using Astal.Bindings.AstalGtk4;

public class Program
{

    public static unsafe void Main(string[] args)
    {
        Console.WriteLine("Initializing Astal Application...");
        _AstalApplication* app = AstalGtk4Interop.astal_application_new();
        
        Console.WriteLine("Creating Astal Window...");
        _AstalWindow* window = AstalGtk4Interop.astal_window_new();
        
        fixed (byte* ns = "my-namespace"u8)
        {
            AstalGtk4Interop.astal_window_set_namespace(window, (sbyte*)ns);
        }
        
        AstalGtk4Interop.astal_window_set_monitor(window, 0);
        
        Console.WriteLine("Application and Window created via Interop.");
        
        // Uncomment the following line to run the application main loop.
        // It might fail if a Wayland or X11 session is not available.
         g_application_run((IntPtr)app, args.Length, args);
    }
}