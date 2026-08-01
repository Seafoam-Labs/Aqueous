const std = @import("std");

pub const Backend = enum {
    standard,
    aur,
    flatpak,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .standard => "Arch repository",
            .aur => "AUR",
            .flatpak => "Flatpak",
        };
    }
};

pub const PackageSpec = struct {
    backend: Backend,
    name: []const u8,
    user_scope: bool = false,
    remote: ?[]const u8 = null,
};

pub const Application = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    package: PackageSpec,
    selected_by_default: bool = false,
};

pub const Section = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    applications: []const Application,
};

pub fn validate(sections: []const Section) !void {
    for (sections, 0..) |section, section_index| {
        if (section.id.len == 0 or section.title.len == 0 or section.applications.len == 0) {
            return error.InvalidSection;
        }

        for (sections[0..section_index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, section.id)) return error.DuplicateSectionId;
        }

        for (section.applications, 0..) |application, application_index| {
            if (application.id.len == 0 or application.name.len == 0 or
                application.package.name.len == 0)
            {
                return error.InvalidApplication;
            }
            if (application.package.backend != .flatpak and
                (application.package.user_scope or application.package.remote != null))
            {
                return error.InvalidPackageOptions;
            }

            for (section.applications[0..application_index]) |earlier| {
                if (std.mem.eql(u8, earlier.id, application.id)) {
                    return error.DuplicateApplicationId;
                }
            }
            for (sections[0..section_index]) |earlier_section| {
                for (earlier_section.applications) |earlier| {
                    if (std.mem.eql(u8, earlier.id, application.id)) {
                        return error.DuplicateApplicationId;
                    }
                }
            }
        }
    }
}

test "catalog validation accepts composable sections" {
    const apps = [_]Application{.{
        .id = "browser",
        .name = "Browser",
        .description = "Browse the web",
        .package = .{ .backend = .standard, .name = "browser" },
    }};
    const sections = [_]Section{.{
        .id = "web",
        .title = "Web",
        .description = "Web applications",
        .applications = &apps,
    }};
    try validate(&sections);
}

test "catalog validation rejects duplicate application ids" {
    const first = [_]Application{.{
        .id = "same",
        .name = "One",
        .description = "One",
        .package = .{ .backend = .standard, .name = "one" },
    }};
    const second = [_]Application{.{
        .id = "same",
        .name = "Two",
        .description = "Two",
        .package = .{ .backend = .flatpak, .name = "org.example.Two", .user_scope = true },
    }};
    const sections = [_]Section{
        .{ .id = "one", .title = "One", .description = "", .applications = &first },
        .{ .id = "two", .title = "Two", .description = "", .applications = &second },
    };
    try std.testing.expectError(error.DuplicateApplicationId, validate(&sections));
}
