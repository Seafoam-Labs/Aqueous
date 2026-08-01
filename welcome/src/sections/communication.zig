const catalog = @import("../catalog.zig");

const applications = [_]catalog.Application{
    .{
        .id = "discord",
        .name = "Discord",
        .description = "Communities, voice, and video chat",
        .package = .{ .backend = .standard, .name = "discord" },
    },
    .{
        .id = "telegram",
        .name = "Telegram",
        .description = "Fast, cloud-based messaging",
        .package = .{
            .backend = .flatpak,
            .name = "org.telegram",
            .user_scope = true,
            .remote = "flathub",
        },
    },
};

pub const section: catalog.Section = .{
    .id = "communication",
    .title = "Communication",
    .description = "Stay in touch with teams and communities.",
    .applications = &applications,
};
