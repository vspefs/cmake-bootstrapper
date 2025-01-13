const std = @import("std");

// TODO: learn how to fallthrough in Zig
pub fn getCMakeVariableFromLine(line: []const u8, name: []const u8) ?[]const u8 {
    for (line) |chr| {
        if (std.ascii.isWhitespace(chr)) {
            continue;
        } else if (chr == '#') {
            return null;
        } else {
            break;
        }
    }
    if (std.mem.indexOf(u8, line, "set")) |set_pos| {
        if (std.mem.indexOfPosLinear(u8, line, set_pos + 4, name)) |ret| {
            var begin = ret + name.len + 1;
            var end = begin + 1;
            var state: enum { finding_begin, finding_end } = .finding_begin;
            while (end < line.len) {
                if (state == .finding_begin) {
                    if (!std.ascii.isWhitespace(line[begin])) {
                        state = .finding_end;
                    } else {
                        begin += 1;
                        end += 1;
                    }
                } else { // state == .finding_end
                    if (std.ascii.isWhitespace(line[end]) or line[end] == ')') {
                        return line[begin..end];
                    } else {
                        end += 1;
                    }
                }
            }
        }
    }
    return null;
}
