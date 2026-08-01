const catalog = @import("../catalog.zig");

const applications = [_]catalog.Application{
    .{
        .id = "firefox",
        .name = "Firefox",
        .description = "Private, extensible web browser",
        .package = .{ .backend = .standard, .name = "firefox" },
    },
    .{
        .id = "chromium",
        .name = "Chromium",
        .description = "Open-source Chromium web browser",
        .package = .{ .backend = .standard, .name = "chromium" },
    },
};

pub const section: catalog.Section = .{
    .id = "web",
    .title = "Web",
    .description = "Choose one or more browsers.",
    .applications = &applications,
};
