const std = @import("std");

pub const DeprecatedWriter = std.fs.File.DeprecatedWriter;

pub fn stdout() DeprecatedWriter {
    return std.fs.File.stdout().deprecatedWriter();
}

pub fn stderr() DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

pub const JsonWriter = struct {
    adapter: DeprecatedWriter.Adapter,

    pub fn init(dw: DeprecatedWriter, buf: []u8) JsonWriter {
        return .{ .adapter = dw.adaptToNewApi(buf) };
    }

    pub fn stringify(self: *JsonWriter) std.json.Stringify {
        return .{ .writer = &self.adapter.new_interface };
    }
};
