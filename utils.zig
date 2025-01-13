const CMakeVersion = struct {
    major: u8,
    minor: u8,
    patch: u32,
    rc: ?u8 = null,
    pub fn toString(self: CMakeVersion, alloc: std.mem.Allocator) ![]const u8 {
        if (self.rc) |_| {
            return try std.fmt.allocPrint(alloc, "{d}.{d}.{d}-rc{d}", .{ self.major, self.minor, self.patch, self.rc.? });
        } else {
            return try std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        }
    }
};

pub fn getCMakeVersion(src_root: Dir) !CMakeVersion {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer {
        if (gpa.deinit() == .leak) {
            @panic("Leaked memory in getCMakeVersion");
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    var file = try src_root.openFile("Source/CMakeVersion.cmake", .{});
    defer file.close();
    var from_file = file.reader();

    var line = ArrayList(u8).init(alloc);
    try line.ensureTotalCapacity(128);
    defer line.deinit();

    var major: ?u8 = null;
    var minor: ?u8 = null;
    var patch: ?u32 = null;
    var rc: ?u8 = null;

    while (major == null or minor == null or patch == null or rc == null) {
        line.clearRetainingCapacity();
        const to_line = line.fixedWriter();
        from_file.streamUntilDelimiter(to_line, '\n', null) catch |err| {
            if (err == error.EndOfStream) {
                break;
            }
        };

        if (cmake_utils.getCMakeVariableFromLine(line.items, "CMake_VERSION_MAJOR")) |ret| {
            major = try std.fmt.parseInt(u8, ret, 10);
        }
        if (cmake_utils.getCMakeVariableFromLine(line.items, "CMake_VERSION_MINOR")) |ret| {
            minor = try std.fmt.parseInt(u8, ret, 10);
        }
        if (cmake_utils.getCMakeVariableFromLine(line.items, "CMake_VERSION_PATCH")) |ret| {
            patch = try std.fmt.parseInt(u32, ret, 10);
        }
        if (cmake_utils.getCMakeVariableFromLine(line.items, "CMake_VERSION_RC")) |ret| {
            rc = try std.fmt.parseInt(u8, ret, 10);
        }
    }

    if (major == null or minor == null or patch == null) {
        return Error.InvalidCMakeVersionFile;
    } else {
        return CMakeVersion{ .major = major.?, .minor = minor.?, .patch = patch.?, .rc = rc };
    }
}

const Error = error{
    InvalidCMakeVersionFile,
};

const ArrayList = std.ArrayList;
const Dir = std.fs.Dir;

const std = @import("std");
const cmake_utils = @import("cmake.zig");
