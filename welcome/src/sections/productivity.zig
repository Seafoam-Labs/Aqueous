const catalog = @import("../catalog.zig");

const applications = [_]catalog.Application{
    .{
        .id = "libreoffice",
        .name = "LibreOffice",
        .description = "Documents, spreadsheets, and presentations",
        .package = .{ .backend = .standard, .name = "libreoffice-fresh" },
    },
    .{
        .id = "thunderbird",
        .name = "Thunderbird",
        .description = "Email, calendar, and contacts",
        .package = .{ .backend = .standard, .name = "thunderbird" },
    },
};

pub const section: catalog.Section = .{
    .id = "productivity",
    .title = "Productivity",
    .description = "Everyday tools for work and study.",
    .applications = &applications,
};
