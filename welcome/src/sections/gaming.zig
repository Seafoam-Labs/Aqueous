const catalog = @import("../catalog.zig");

const applications = [_]catalog.Application{
    .{
        .id = "steam",
        .name = "Steam",
        .description = "Game library, store, and community",
        .package = .{ .backend = .standard, .name = "steam" },
    },
    .{
        .id = "heroic",
        .name = "Heroic Games Launcher",
        .description = "Launch Epic, GOG, and Amazon games",
        .package = .{
            .backend = .flatpak,
            .name = "com.heroicgameslauncher.hgl",
            .user_scope = true,
            .remote = "flathub",
        },
    },
};

pub const section: catalog.Section = .{
    .id = "gaming",
    .title = "Gaming",
    .description = "Install launchers for your game libraries.",
    .applications = &applications,
};
