pub const util = @import("sql/util.zig");
pub const GrammarParser = @import("sql/GrammarParser.zig");
pub const grammar = @import("sql/grammar.zig");
pub const Tokenizer = @import("sql/Tokenizer.zig");
pub const Parser = @import("sql/Parser.zig");

const std = @import("std");
const u = util;

pub const Database = struct {
    allocator: u.Allocator,

    pub fn init(allocator: u.Allocator) !Database {
        return Database{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Database) void {
        _ = self;
    }

    pub fn run(self: *Database, sql: []const u8) ![]const []const Value {
        var arena = u.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const sql_z = try arena.allocator().dupeZ(u8, sql);
        var tokenizer = Tokenizer.init(&arena, sql_z);
        try tokenizer.tokenize();
        var parser = Parser.init(&arena, tokenizer, false);
        const root_id = try parser.parse("root") orelse return error.ParseError;
        //const root_id = (try parser.parse("root")) orelse {
        //    u.dump("Failure!");
        //    parser = Parser.init(&arena, tokenizer, true);
        //    _ = try parser.parse("root");
        //    u.dump(tokenizer.tokens.items);
        //    //u.dump(parser.failures.items);
        //    if (parser.greatestFailure()) |failure| {
        //        u.dump(failure);
        //        const failure_pos = parser.getFailureSourcePos(failure);
        //        std.debug.print("{s} !!! {s}\n", .{
        //            sql[0..failure_pos],
        //            sql[failure_pos..],
        //        });
        //    }
        //    unreachable;
        //};
        _ = root_id;
        //try countRuleUsage(parser, root_id);
        //u.dump(parser);
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

var rule_usage = u.DeepHashMap([]const u8, struct { q: usize, s: usize }).init(std.heap.page_allocator);

fn countRuleUsage(parser: Parser, root_id: Parser.NodeId("root")) !void {
    var used_rules = u.DeepHashSet([]const u8).init(std.heap.page_allocator);
    defer used_rules.deinit();
    try collectUsedRules(parser, root_id.id, &used_rules);
    var iter = used_rules.keyIterator();
    const is_query = root_id.get(parser).statement_or_query.get(parser) == .select;
    while (iter.next()) |rule_name| {
        const entry = try rule_usage.getOrPutValue(rule_name.*, .{ .s = 0, .q = 0 });
        if (is_query)
            entry.value_ptr.q += 1
        else
            entry.value_ptr.s += 1;
    }
}
fn collectUsedRules(parser: Parser, node_id: usize, used_rules: *u.DeepHashSet([]const u8)) !void {
    const node = parser.nodes.items[node_id];
    try used_rules.put(@tagName(node), {});
    for (parser.node_children.items[node_id]) |child_id|
        try collectUsedRules(parser, child_id, used_rules);
}

pub fn dumpRuleUsage() !void {
    const NameAndCount = struct {
        name: []const u8,
        count: @TypeOf(rule_usage.get("").?),
    };
    var counts = u.ArrayList(NameAndCount).init(std.heap.page_allocator);
    defer counts.deinit();
    inline for (@typeInfo(grammar.rules).Struct.decls) |decl|
        try counts.append(.{
            .name = decl.name,
            .count = rule_usage.get(decl.name) orelse .{ .s = 0, .q = 0 },
        });
    std.sort.sort(NameAndCount, counts.items, {}, (struct {
        fn lessThan(_: void, a: NameAndCount, b: NameAndCount) bool {
            return (a.count.q + a.count.s) < (b.count.q + b.count.s);
        }
    }).lessThan);
    u.dump(counts.items);
}
