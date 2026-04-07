using System;

namespace Aqueous.Features.SystemTray
{
    public class TrayItem
    {
        public string ServiceName { get; set; } = "";
        public string ObjectPath { get; set; } = "/StatusNotifierItem";
        public string Id { get; set; } = "";
        public string Title { get; set; } = "";
        public string Status { get; set; } = "Active";
        public string Category { get; set; } = "ApplicationStatus";
        public string IconName { get; set; } = "";
        public (int Width, int Height, byte[] Data)[]? IconPixmap { get; set; }
        public string ToolTipTitle { get; set; } = "";
        public string MenuPath { get; set; } = "";

        public string DisplayName => !string.IsNullOrEmpty(Title) ? Title : Id;
    }
}
