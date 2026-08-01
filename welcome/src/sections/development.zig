const catalog = @import("../catalog.zig");

const applications = [_]catalog.Application{
    .{
        .id = "code",
        .name = "Code",
        .description = "Open-source Visual Studio Code build",
        .package = .{ .backend = .standard, .name = "code" },
    },
    .{
        .id = "ghostty",
        .name = "Ghostty",
        .description = "Fast, native terminal emulator",
        .package = .{ .backend = .standard, .name = "ghostty" },
    },
};

pub const section: catalog.Section = .{
    .id = "development",
    .title = "Development",
    .description = "Editors and terminal tools for building software.",
    .applications = &applications,
};
