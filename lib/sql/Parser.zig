const std = @import("std");
const sql = @import("../sql.zig");
const u = sql.util;
const rules = sql.grammar.rules;
const types = sql.grammar.types;
const Node = sql.grammar.Node;

const Self = @This();
arena: *u.ArenaAllocator,
allocator: u.Allocator,
// Last token is .eof. We don't use a sentinel type because I got lazy when trying to figure out the correct casts.
tokens: []const sql.Tokenizer.TokenAndRange,
debug: bool,
pos: usize,
nodes: u.ArrayList(Node),
memo: u.DeepHashMap(MemoKey, MemoValue),
// debug only
rule_name_stack: u.ArrayList([]const u8),
failures: u.ArrayList(Failure),

pub const MemoKey = struct {
    rule_name: []const u8,
    start_pos: usize,
};

pub const MemoValue = struct {
    node_id: ?usize,
    end_pos: usize,
    was_used: bool,
};

pub const Failure = struct {
    rule_names: []const []const u8,
    pos: usize,
    remaining_tokens: []const sql.Tokenizer.TokenAndRange,
};

pub const Error = error{
    OutOfMemory,
};

pub fn NodeId(comptime rule_name_: []const u8) type {
    return struct {
        pub const rule_name = rule_name_;
        pub const T = @field(types, rule_name);
        id: usize,
        pub fn get(self: @This(), nodes: []const Node) T {
            return @field(nodes[self.id], rule_name);
        }
    };
}

pub fn init(
    arena: *u.ArenaAllocator,
    tokens: []const sql.Tokenizer.TokenAndRange,
    debug: bool,
) Self {
    const allocator = arena.allocator();
    return Self{
        .arena = arena,
        .allocator = allocator,
        .tokens = tokens,
        .debug = debug,
        .pos = 0,
        .nodes = u.ArrayList(Node).init(allocator),
        .memo = u.DeepHashMap(MemoKey, MemoValue).init(allocator),
        .rule_name_stack = u.ArrayList([]const u8).init(allocator),
        .failures = u.ArrayList(Failure).init(allocator),
    };
}

pub fn push(self: *Self, comptime rule_name: []const u8, node: @field(types, rule_name)) !NodeId(rule_name) {
    const id = self.nodes.items.len;
    try self.nodes.append(@unionInit(Node, rule_name, node));
    return .{ .id = id };
}

pub fn get(self: *Self, node_id: anytype) @TypeOf(node_id).T {
    return @field(self.nodes.items[node_id.id], @TypeOf(node_id).rule_name);
}

pub fn parse(self: *Self, comptime rule_name: []const u8) Error!?NodeId(rule_name) {
    if (@field(sql.grammar.is_left_recursive, rule_name)) {
        const start_pos = self.pos;
        const memo_key = MemoKey{
            .rule_name = rule_name,
            .start_pos = start_pos,
        };
        if (self.memo.getEntry(memo_key)) |entry| {
            entry.value_ptr.was_used = true;
            self.pos = entry.value_ptr.end_pos;
            return if (entry.value_ptr.node_id) |id|
                NodeId(rule_name){ .id = id }
            else
                null;
        } else {
            var last_end_pos: usize = self.pos;
            var last_node_id: ?usize = null;
            while (true) {
                try self.memo.put(memo_key, .{
                    .end_pos = last_end_pos,
                    .node_id = last_node_id,
                    .was_used = false,
                });
                self.pos = start_pos;
                const node_id = if (try self.parsePush(rule_name)) |id| id.id else null;
                const end_pos = self.pos;

                if (node_id == null or end_pos < last_end_pos)
                    break;

                last_end_pos = end_pos;
                last_node_id = node_id;

                if (!self.memo.get(memo_key).?.was_used) {
                    try self.memo.put(memo_key, .{
                        .end_pos = last_end_pos,
                        .node_id = last_node_id,
                        .was_used = false,
                    });
                    break;
                }
            }
            self.pos = last_end_pos;
            return if (last_node_id) |id|
                NodeId(rule_name){ .id = id }
            else
                null;
        }
    } else {
        return self.parsePush(rule_name);
    }
}

pub fn parsePush(self: *Self, comptime rule_name: []const u8) Error!?NodeId(rule_name) {
    if (try self.parseNode(rule_name)) |node|
        return try self.push(rule_name, node)
    else
        return null;
}

pub fn parseNode(self: *Self, comptime rule_name: []const u8) Error!?@field(types, rule_name) {
    if (self.debug) try self.rule_name_stack.append(rule_name);
    defer if (self.debug) {
        _ = self.rule_name_stack.pop();
    };
    if (self.debug)
        u.dump(.{ rule_name, self.pos, self.tokens[self.pos].token });

    const ResultType = @field(types, rule_name);
    switch (@field(rules, rule_name)) {
        .token => |token| {
            const self_token = self.tokens[self.pos];
            if (self_token.token == token) {
                self.pos += 1;
                return self_token.range;
            } else {
                return self.fail(rule_name);
            }
        },
        .one_of => |one_ofs| {
            const start_pos = self.pos;
            inline for (one_ofs) |one_of| {
                switch (one_of) {
                    .choice => |rule_ref| {
                        if (try self.parse(rule_ref.rule_name)) |result| {
                            return initChoice(ResultType, rule_ref, result);
                        } else {
                            // Try next one_of.
                            self.pos = start_pos;
                        }
                    },
                    .committed_choice => |rule_refs| {
                        if (try self.parse(rule_refs[0].rule_name)) |_| {
                            // Reset after lookahead
                            self.pos = start_pos;
                            if (try self.parse(rule_refs[1].rule_name)) |result| {
                                return initChoice(ResultType, rule_refs[1], result);
                            } else {
                                // Already committed.
                                return self.fail(rule_name);
                            }
                        } else {
                            // Try next one_of.
                            self.pos = start_pos;
                        }
                    },
                }
            }
            return self.fail(rule_name);
        },
        .all_of => |all_ofs| {
            var result: ResultType = undefined;
            inline for (all_ofs) |all_of| {
                if (try self.parse(all_of.rule_name)) |field_result| {
                    if (all_of.field_name) |field_name| {
                        @field(result, field_name) = field_result;
                    }
                } else {
                    return self.fail(rule_name);
                }
            }
            return result;
        },
        .optional => |optional| {
            const start_pos = self.pos;
            if (try self.parse(optional.rule_name)) |optional_result| {
                return optional_result;
            } else {
                self.pos = start_pos;
                // This is a succesful null, not a failure.
                return @as(ResultType, null);
            }
        },
        .repeat => |repeat| {
            var results = u.ArrayList(NodeId(repeat.element.rule_name)).init(self.allocator);
            while (true) {
                const start_pos = self.pos;
                if (repeat.separator) |separator| {
                    if (results.items.len > 0) {
                        if (try self.parse(separator.rule_name) == null) {
                            self.pos = start_pos;
                            break;
                        }
                    }
                }
                if (try self.parse(repeat.element.rule_name)) |result| {
                    try results.append(result);
                } else {
                    self.pos = start_pos;
                    break;
                }
            }
            if (results.items.len >= repeat.min_count)
                return results.toOwnedSlice()
            else
                return self.fail(rule_name);
        },
    }
}

fn fail(self: *Self, comptime rule_name: []const u8) Error!?@field(types, rule_name) {
    if (self.debug)
        try self.failures.append(.{
            .rule_names = try self.allocator.dupe([]const u8, self.rule_name_stack.items),
            .pos = self.pos,
            .remaining_tokens = self.tokens[self.pos..],
        });
    return null;
}

fn initChoice(comptime ChoiceType: type, comptime rule_ref: sql.grammar.RuleRef, result: anytype) ChoiceType {
    return switch (@typeInfo(ChoiceType)) {
        .Union => @unionInit(ChoiceType, rule_ref.field_name.?, result),
        .Enum => @field(ChoiceType, rule_ref.rule_name),
        else => unreachable,
    };
}
