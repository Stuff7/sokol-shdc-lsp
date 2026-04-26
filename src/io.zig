const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{
    FileStatFailed,
    FileTooLarge,
    ReadFailed,
};

pub fn readUntilAny(r: *Io.Reader, needles: []const []const u8) ?struct { []const u8, usize } {
    var max_len: usize = 0;
    for (needles) |needle| max_len = @max(max_len, needle.len);

    var idx: usize = 0;
    const start = r.seek;
    const end = end: while (true) {
        const peeked = r.peek(max_len) catch return null;
        const end = r.seek;
        for (needles, 0..) |needle, i| {
            if (std.ascii.startsWithIgnoreCase(peeked, needle)) {
                idx = i;
                r.toss(needle.len);
                break :end end;
            }
        }
        r.toss(1);
    } else return null;

    return .{ r.buffer[start..end], idx };
}

pub fn readUntilSlice(r: *Io.Reader, needle: []const u8) ?[]const u8 {
    const start = r.seek;
    const end = end: while (true) {
        const peeked = r.peek(needle.len) catch return null;
        const end = r.seek;
        if (std.ascii.eqlIgnoreCase(peeked, needle)) {
            r.toss(peeked.len);
            break :end end;
        }
        r.toss(1);
    } else return null;

    return r.buffer[start..end];
}

pub fn findRelativeReference(r: *Io.Reader) ?[]const u8 {
    while (true) {
        var peeked: []const u8 = r.takeDelimiterInclusive('\n') catch return null;
        peeked = std.mem.trim(u8, peeked, " \n");
        const sep = std.mem.indexOfScalar(u8, peeked, ' ') orelse return null;
        peeked = peeked[sep + 1 ..];
        if (peeked[0] != '/') return peeked;
    }

    return null;
}

pub fn readFileToString(file: std.fs.File, allocator: Allocator, max_size: usize) Error![]u8 {
    const file_size = file.getEndPos() catch return error.FileStatFailed;
    if (file_size > max_size) return error.FileTooLarge;
    var buf: [1024]u8 = undefined;
    var r = file.reader(&buf);
    return r.interface.readAlloc(allocator, file_size) catch return error.ReadFailed;
}
