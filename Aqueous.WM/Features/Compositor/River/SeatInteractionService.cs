using System;

namespace Aqueous.Features.Compositor.River
{
    internal sealed class SeatInteractionService
    {
        private readonly RiverWindowManagerClient _client;

        public SeatInteractionService(RiverWindowManagerClient client)
        {
            _client = client;
        }

        public void HandleWindowInteraction(IntPtr windowProxy, IntPtr seatProxy)
        {
            _client.SetFocusedWindow(windowProxy, seatProxy);
        }

        public void HandleShellSurfaceInteraction(IntPtr shellSurfaceProxy, IntPtr seatProxy)
        {
            _client.SetFocusedShellSurface(shellSurfaceProxy, seatProxy);
        }
    }
}
