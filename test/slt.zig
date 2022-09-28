const std = @import("std");
const sql = @import("../lib/sql.zig");
const u = sql.util;

const allocator = std.heap.c_allocator;

pub fn ReturnError(f: anytype) type {
    const Return = @typeInfo(@TypeOf(f)).Fn.return_type.?;
    return @typeInfo(Return).ErrorUnion.error_set;
}

const TestError = ReturnError(runStatement) || ReturnError(runQuery);

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // discard executable name

    var passes: usize = 0;
    var errors = u.DeepHashMap(TestError, usize).init(allocator);
    defer errors.deinit();

    var bnf_parser = sql.BnfParser.init(allocator);
    try bnf_parser.parseDefs();

    file: while (args.next()) |slt_path| {
        std.debug.print("Running {}\n", .{std.zig.fmtEscapes(slt_path)});

        var database = try sql.Database.init(allocator, &bnf_parser);
        defer database.deinit();

        var bytes = u.ArrayList(u8).init(allocator);
        defer bytes.deinit();

        {
            const file = try std.fs.cwd().openFile(slt_path, .{});
            defer file.close();

            try file.reader().readAllArrayList(&bytes, std.math.maxInt(usize));
        }

        var cases = std.mem.split(u8, bytes.items, "\n\n");
        while (cases.next()) |case_untrimmed| {
            const case = std.mem.trim(u8, case_untrimmed, " \n");
            if (case.len == 0) continue;

            errdefer std.debug.print("Case:\n{}\n\n", .{std.zig.fmtEscapes(case)});
            var lines = std.mem.split(u8, case, "\n");

            // might have to loop a few times to get to the actual header
            header: while (lines.next()) |header| {
                errdefer std.debug.print("Header:\n{}\n\n", .{std.zig.fmtEscapes(header)});

                if (std.mem.startsWith(u8, header, "#")) continue :header;
                var words = std.mem.split(u8, header, " ");
                const kind = words.next() orelse return error.UnexpectedInput;
                if (std.mem.eql(u8, kind, "hash-threshold")) {
                    // TODO
                    break :header;
                } else if (std.mem.eql(u8, kind, "halt")) {
                    continue :file;
                } else if (std.mem.eql(u8, kind, "skipif") or std.mem.eql(u8, kind, "onlyif")) {
                    // Only run tests that sqlite/mysql/postgres agree on
                    if (lines.next()) |line|
                        if (std.mem.eql(u8, line, "halt"))
                            continue :file;
                    break :header;
                } else if (std.mem.eql(u8, kind, "statement")) {
                    // Statements look like:
                    // statement ok/error
                    // ...sql...
                    const expected_bytes = words.next() orelse return error.UnexpectedInput;
                    const expected = if (std.mem.eql(u8, expected_bytes, "ok"))
                        StatementExpected.ok
                    else if (std.mem.eql(u8, expected_bytes, "error"))
                        StatementExpected.err
                    else
                        return error.UnexpectedInput;
                    const statement = std.mem.trim(u8, case[lines.index.?..], "\n");
                    if (runStatement(&database, statement, expected)) |_|
                        passes += 1
                    else |err|
                        try incCount(&errors, err);
                    break :header;
                } else if (std.mem.eql(u8, kind, "query")) {
                    // Queries look like
                    // query types sort_mode? label?
                    // ...sql...
                    // ----
                    // ...expected...
                    const types_bytes = words.next().?;

                    const types = try allocator.alloc(sql.Type, types_bytes.len);
                    defer allocator.free(types);

                    for (types) |*typ, i|
                        typ.* = switch (types_bytes[i]) {
                            'T' => sql.Type.text,
                            'I' => sql.Type.integer,
                            'R' => sql.Type.real,
                            else => return error.UnexpectedInput,
                        };
                    const sort_mode_bytes = words.next() orelse "nosort";
                    const sort_mode = if (std.mem.eql(u8, sort_mode_bytes, "nosort"))
                        SortMode.no_sort
                    else if (std.mem.eql(u8, sort_mode_bytes, "rowsort"))
                        SortMode.row_sort
                    else if (std.mem.eql(u8, sort_mode_bytes, "valuesort"))
                        SortMode.value_sort
                    else
                        return error.UnexpectedInput;
                    const label = words.next();
                    var query_and_expected_iter = std.mem.split(u8, case[lines.index.?..], "----");
                    const query = std.mem.trim(u8, query_and_expected_iter.next().?, "\n");
                    const expected = std.mem.trim(u8, query_and_expected_iter.next() orelse "", "\n");
                    if (runQuery(&database, query, types, sort_mode, label, expected)) |_|
                        passes += 1
                    else |err|
                        try incCount(&errors, err);
                    break :header;
                } else return error.UnexpectedInput;
            }
        }
    }

    u.dump(errors);
    std.debug.print("passes => {}", .{passes});
}

fn incCount(hash_map: anytype, key: anytype) !void {
    const entry = try hash_map.getOrPut(key);
    if (!entry.found_existing)
        entry.value_ptr.* = 0;
    entry.value_ptr.* += 1;
}

const StatementExpected = enum {
    ok,
    err,
};

const SortMode = enum {
    no_sort,
    row_sort,
    value_sort,
};

fn runStatement(database: *sql.Database, statement: []const u8, expected: StatementExpected) !void {
    if (database.runStatement(statement)) |_| {
        switch (expected) {
            .ok => return,
            .err => return error.StatementShouldError,
        }
    } else |err| {
        switch (expected) {
            .ok => return err,
            .err => switch (err) {
                error.Unimplemented, error.NoParse, error.AmbiguousParse => return err,
                else => return,
            },
        }
    }
}

fn runQuery(database: *sql.Database, query: []const u8, types: []const sql.Type, sort_mode: SortMode, label: ?[]const u8, expected_output: []const u8) !void {
    _ = label; // TODO handle labels
    // TODO handle hashing

    const rows = try database.runQuery(query);

    for (rows) |row| {
        if (row.len != types.len)
            return error.WrongNumberOfColumnsReturned;
    }

    const hashed = std.mem.containsAtLeast(u8, expected_output, 1, "values hashing to");
    var arena = u.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const actual_output = try produceQueryOutput(&arena, rows, types, sort_mode, hashed);
    return std.testing.expectEqualStrings(expected_output, actual_output);
}

fn produceQueryOutput(arena: *u.ArenaAllocator, rows: []const []const sql.Value, types: []const sql.Type, sort_mode: SortMode, hashed: bool) ![]const u8 {
    var actual_outputs = u.ArrayList([]const u8).init(arena.allocator());
    for (rows) |row| {
        switch (sort_mode) {
            .no_sort, .value_sort => {
                for (types) |typ, i|
                    try actual_outputs.append(try formatValue(arena, typ, row[i]));
            },
            .row_sort => {
                var row_output = u.ArrayList([]const u8).init(arena.allocator());
                for (types) |typ, i|
                    try row_output.append(try formatValue(arena, typ, row[i]));
                try actual_outputs.append(try std.mem.join(arena.allocator(), "\n", row_output.items));
            },
        }
    }

    switch (sort_mode) {
        .no_sort => {},
        .value_sort, .row_sort => std.sort.sort(
            []const u8,
            actual_outputs.items,
            {},
            (struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }).lessThan,
        ),
    }

    const actual_output = try std.mem.join(arena.allocator(), "\n", actual_outputs.items);

    if (hashed) {
        var hasher = std.crypto.hash.Md5.init(.{});
        hasher.update(actual_output);
        hasher.update("\n");
        var hash: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        hasher.final(&hash);
        return std.fmt.allocPrint(arena.allocator(), "{} values hashing to {s}", .{ rows.len * types.len, std.fmt.fmtSliceHexLower(&hash) });
    } else {
        return actual_output;
    }
}

fn formatValue(arena: *u.ArenaAllocator, typ: sql.Type, value: sql.Value) ![]const u8 {
    return switch (value) {
        .nul => "NULL",
        .integer => |integer| switch (typ) {
            .integer, .text => std.fmt.allocPrint(arena.allocator(), "{}", .{integer}),
            .real => std.fmt.allocPrint(arena.allocator(), "{d:.3}", .{@intToFloat(f64, integer)}),
            .nul, .blob => unreachable, // tests only contain I T R
        },
        .real => |real| switch (typ) {
            .integer => error.UnexpectedFormatComboRealinteger,
            .text => error.UnexpectedFormatComboRealText,
            .real => std.fmt.allocPrint(arena.allocator(), "{d:.3}", .{real}),
            .nul, .blob => unreachable, // tests only contain I T R
        },
        .text => |text| switch (typ) {
            .text => text,
            .integer => "0", // sqlite, why?
            .real => error.UnexpectedFormatComboTextReal,
            .nul, .blob => unreachable, // tests only contain I T R
        },
        .blob => return error.UnexpectedFormatComboBlob,
    };
}

fn testProduceQueryOutput(rows: []const []const sql.Value, types: []const sql.Type, sort_mode: SortMode, hashed: bool, expected: []const u8) !void {
    var arena = u.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const actual = try produceQueryOutput(&arena, rows, types, sort_mode, hashed);
    return std.testing.expectEqualStrings(expected, actual);
}

test {
    try testProduceQueryOutput(
        &.{
            &.{
                .{ .integer = 222 },
                .{ .integer = 117 },
                .{ .integer = -3 },
                .{ .integer = 1180 },
                .{ .integer = 117 },
                .{ .integer = 1 },
            },
            &.{
                .{ .integer = 222 },
                .{ .integer = 120 },
                .{ .integer = -3 },
                .{ .integer = 1240 },
                .{ .integer = 122 },
                .{ .integer = 1 },
            },
            &.{
                .{ .integer = 444 },
                .{ .integer = 103 },
                .{ .integer = 4 },
                .{ .integer = 1000 },
                .{ .integer = 102 },
                .{ .integer = 2 },
            },
        },
        &.{
            sql.Type.integer,
            sql.Type.integer,
            sql.Type.integer,
            sql.Type.integer,
            sql.Type.integer,
            sql.Type.integer,
        },
        SortMode.no_sort,
        true,
        "18 values hashing to 195ca5c056027e19b7098549fb30a259",
    );

    try testProduceQueryOutput(
        &.{
            &.{.{ .integer = 9 }},
            &.{.{ .integer = 31 }},
            &.{.{ .integer = 116 }},
            &.{.{ .integer = 240 }},
            &.{.{ .integer = 300 }},
            &.{.{ .integer = 386 }},
            &.{.{ .integer = 799 }},
            &.{.{ .integer = 863 }},
            &.{.{ .integer = 973 }},
        },
        &.{
            sql.Type.integer,
        },
        SortMode.value_sort,
        true,
        "9 values hashing to 0242ff524f6efe4a8115ad23f4d8659a",
    );
}
