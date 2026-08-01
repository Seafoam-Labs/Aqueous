const catalog = @import("../catalog.zig");

const applications = [_]catalog.Application{
    .{
        .id = "vlc",
        .name = "VLC",
        .description = "Play video, music, and network streams",
        .package = .{ .backend = .standard, .name = "vlc" },
    },
    .{
        .id = "obs-studio",
        .name = "OBS Studio",
        .description = "Record and stream your screen",
        .package = .{
            .backend = .flatpak,
            .name = "com.obsproject.Studio",
            .user_scope = true,
            .remote = "flathub",
        },
    },
};

pub const section: catalog.Section = .{
    .id = "media",
    .title = "Media",
    .description = "Playback, recording, and streaming.",
    .applications = &applications,
};
