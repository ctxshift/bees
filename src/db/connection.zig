const std = @import("std");
const sqlite = @import("sqlite");

pub const Db = sqlite.Database;

pub fn open(path: [*:0]const u8) !Db {
    const db = try Db.open(.{
        .path = path,
        .mode = .ReadWrite,
        .create = true,
    });
    errdefer db.close();

    // Enable WAL mode for concurrent read/write
    db.exec("PRAGMA journal_mode=WAL;", .{}) catch {};
    db.exec("PRAGMA foreign_keys=ON;", .{}) catch {};
    db.exec("PRAGMA busy_timeout=5000;", .{}) catch {};

    return db;
}

pub fn openMemory() !Db {
    const db = try Db.open(.{});
    db.exec("PRAGMA foreign_keys=ON;", .{}) catch {};
    return db;
}
