const catalog = @import("catalog.zig");

pub const sections = [_]catalog.Section{
    @import("sections/web.zig").section,
    @import("sections/communication.zig").section,
    @import("sections/productivity.zig").section,
    @import("sections/media.zig").section,
    @import("sections/development.zig").section,
    @import("sections/gaming.zig").section,
};

pub const application_count = count: {
    var result: usize = 0;
    for (sections) |section| result += section.applications.len;
    break :count result;
};

pub fn applicationAt(wanted: usize) ?catalog.Application {
    var index: usize = 0;
    for (sections) |section| {
        for (section.applications) |application| {
            if (index == wanted) return application;
            index += 1;
        }
    }
    return null;
}

pub fn globalIndex(section_index: usize, application_index: usize) usize {
    var result: usize = application_index;
    for (sections[0..section_index]) |section| result += section.applications.len;
    return result;
}

test "built-in catalog is valid and indexable" {
    try catalog.validate(&sections);
    var index: usize = 0;
    for (sections) |section| {
        for (section.applications) |application| {
            try @import("std").testing.expectEqualStrings(application.id, applicationAt(index).?.id);
            index += 1;
        }
    }
    try @import("std").testing.expectEqual(application_count, index);
    try @import("std").testing.expect(applicationAt(index) == null);
}
