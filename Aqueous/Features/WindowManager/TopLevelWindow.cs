namespace Aqueous.Features.WindowManager
{
    public class TopLevelWindow
    {
        public int Id { get; set; }
        public string Title { get; set; } = "";
        public string AppId { get; set; } = "";
        public int OutputId { get; set; }
        public int WorkspaceX { get; set; }
        public int WorkspaceY { get; set; }
        public bool Focused { get; set; }
        public bool Minimized { get; set; }
        public bool Fullscreen { get; set; }
        public string Role { get; set; } = "";
        public (int X, int Y, int W, int H) Geometry { get; set; }
    }
}
