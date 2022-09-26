pub const util = @import("sql/util.zig");
pub const BnfParser = @import("sql/BnfParser.zig");

const std = @import("std");
const u = util;

pub const Database = struct {
    allocator: u.Allocator,

    pub fn init(allocator: u.Allocator) !Database {
        return Database{ .allocator = allocator };
    }

    pub fn deinit(self: *Database) void {
        _ = self;
    }

    pub fn runStatement(self: *Database, statement: []const u8) !void {
        _ = self;
        _ = statement;
        return error.Unimplemented;
    }

    pub fn runQuery(self: *Database, query: []const u8) ![]const []const Value {
        _ = self;
        _ = query;
        return error.Unimplemented;
    }
};

pub const Type = enum {
    nul,
    integer,
    real,
    text,
    blob,
};

/// https://www.sqlite.org/datatype3.html
pub const Value = union(Type) {
    nul,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,

    // https://www.sqlite.org/datatype3.html#comparisons
};

test {}
