const std = @import("std");
const sql = @import("../sql.zig");
const u = sql.util;
const Node = sql.grammar.Node;
const N = sql.grammar.types; // TODO move these inside Node
const NodeId = sql.Parser.NodeId;

const Self = @This();
arena: *u.ArenaAllocator,
allocator: u.Allocator,
parser: sql.Parser,
database: sql.Database,
relation_exprs: u.ArrayList(RelationExpr),
scalar_exprs: u.ArrayList(ScalarExpr),
next_def_id: usize,

pub const RelationExprId = usize;
pub const ScalarExprId = usize;

pub const StatementExpr = union(enum) {
    create_table: CreateTable,
    create_index: CreateIndex,
    insert: Insert,
    select: RelationExprId,
    drop_table: DropTable,
    drop_index: DropIndex,
    noop,
};

pub const CreateTable = struct {
    name: sql.TableName,
    def: sql.TableDef,
    if_not_exists: bool,
};

pub const CreateIndex = struct {
    name: sql.IndexName,
    def: sql.IndexDef,
    if_not_exists: bool,
};

pub const Insert = struct {
    table_name: sql.TableName,
    query: RelationExprId,
};

pub const DropTable = struct {
    name: sql.TableName,
    if_exists: bool,
};

pub const DropIndex = struct {
    name: sql.TableName,
    if_exists: bool,
};

pub const ColumnDef = struct {
    id: usize,
    column_name: ?[]const u8,
};

/// A reference to some column.
/// When planning:
/// * Use .ref to plan any column_ref/table_column_ref in the parse tree.
/// * Use .def_id to refer to any temporary expression that does not have a sql name.
/// resolveAll converts all ColumnRefs to .def_id
/// arrangeAll converts all ColumnRefs to .ix
pub const ColumnRef = union(enum) {
    /// An unresolved sql column ref
    ref: struct {
        /// null if no table_name
        table_name: ?[]const u8,
        /// null for star
        column_name: ?[]const u8,
    },
    /// A reference to an existing ColumnDef
    def_id: usize,
    /// A reference to input.columns[ix].
    ix: usize,
};

pub const RelationExpr = union(enum) {
    none,
    some,
    map: struct {
        input: RelationExprId,
        column_def: ColumnDef,
        scalar: ScalarExprId,
    },
    filter: struct {
        input: RelationExprId,
        cond: ScalarExprId,
    },
    project: struct {
        input: RelationExprId,
        column_refs: []ColumnRef,
        column_renames: []?[]const u8,
        // Filled in later by resolveAll
        column_defs: ?[]ColumnDef = null,
    },
    unio: struct {
        inputs: [2]RelationExprId,
        all: bool,
    },
    get_table: struct {
        table_name: []const u8,
        // Filled in later by resolveAll
        column_defs: ?[]ColumnDef = null,
    },
    distinct: RelationExprId,
    order_by: struct {
        input: RelationExprId,
        orderings: []Ordering,
    },
    as: struct {
        input: RelationExprId,
        table_name: []const u8,
    },
};

pub const Ordering = struct {
    column_ref: ColumnRef,
    desc: bool,
};

pub const ScalarExpr = union(enum) {
    value: sql.Value,
    column: ColumnRef,
    unary: struct {
        input: ScalarExprId,
        op: UnaryOp,
    },
    binary: struct {
        inputs: [2]ScalarExprId,
        op: BinaryOp,
    },
    in: struct {
        input: ScalarExprId,
        subplan: RelationExprId,
        // We can't plan correlated subqueries, and non-correlated subqueries are always safe to cache
        subplan_cache: ?sql.Evaluator.Relation,
    },
};

pub const UnaryOp = enum {
    is_null,
    is_not_null,
    bool_not,
    bit_not,
    plus,
    minus,
};

pub const BinaryOp = enum {
    bool_and,
    bool_or,
    equal,
    double_equal,
    not_equal,
    is_distinct_from,
    is_not_distinct_from,
    is_not,
    is,
    match,
    like,
    regexp,
    glob,
    not_match,
    not_like,
    not_regexp,
    not_glob,
    less_than,
    greater_than,
    less_than_or_equal,
    greater_than_or_equal,
    plus,
    minus,
    star,
    forward_slash,
    percent,
    shift_left,
    shift_right,
    bit_and,
    bit_or,
};

pub const Error = error{
    OutOfMemory,
    NoPlan,
    AbortPlan,
    InvalidLiteral,
    NoResolve,
    MultipleResolve,
    BadArrange,
};

pub fn init(
    arena: *u.ArenaAllocator,
    parser: sql.Parser,
    database: sql.Database,
) Self {
    const allocator = arena.allocator();
    return Self{
        .arena = arena,
        .allocator = allocator,
        .parser = parser,
        .database = database,
        .relation_exprs = u.ArrayList(RelationExpr).init(allocator),
        .scalar_exprs = u.ArrayList(ScalarExpr).init(allocator),
        .next_def_id = 0,
    };
}

fn nextDefId(self: *Self) usize {
    const id = self.next_def_id;
    self.next_def_id += 1;
    return id;
}

fn pushRelation(self: *Self, relation: RelationExpr) Error!RelationExprId {
    const id = self.relation_exprs.items.len;
    try self.relation_exprs.append(relation);
    return id;
}

fn pushScalar(self: *Self, scalar: ScalarExpr) Error!ScalarExprId {
    const id = self.scalar_exprs.items.len;
    try self.scalar_exprs.append(scalar);
    return id;
}

pub fn planStatement(self: *Self, node_id: anytype) !StatementExpr {
    const p = self.parser;
    const node = node_id.get(p);
    switch (@TypeOf(node)) {
        N.statement_or_query => switch (node) {
            .select => |select| return self.planStatement(select),
            .create => |create| return self.planStatement(create),
            .insert => |insert| return self.planStatement(insert),
            .drop => |drop| return self.planStatement(drop),
            .reindex => return .{ .noop = {} },
            else => return error.NoPlan,
        },
        N.select => {
            const plan = try self.planRelation(node_id);
            try self.resolveAllRelation(plan);
            _ = try self.arrangeAllRelation(plan);
            return .{ .select = plan };
        },
        N.create => switch (node) {
            .create_table => |create_table| return self.planStatement(create_table),
            .create_index => |create_index| return self.planStatement(create_index),
            else => return error.NoPlan,
        },
        N.create_table => {
            const name = node.table_name.getSource(p);
            const defs_expr = node.column_defs.get(p).column_def.get(p);
            var key: ?sql.Key = null;
            const columns = try self.allocator.alloc(sql.ColumnDef, defs_expr.elements.len);
            for (columns) |*column, i| {
                const def_expr = defs_expr.elements[i].get(p);
                column.* = .{
                    .name = def_expr.column_name.getSource(p),
                    .typ = if (def_expr.typ.get(p)) |typ|
                        try self.planType(typ)
                    else
                        null,
                    .nullable = true, // no `NOT NULL` constraints in tests
                };
                if (def_expr.column_constraint.get(p)) |constraint| {
                    switch (constraint.get(p)) {
                        .key => |key_expr_id| {
                            const key_expr = key_expr_id.get(p);
                            key = .{
                                .columns = try self.allocator.dupe(usize, &.{i}),
                                .kind = switch (key_expr.kind.get(p)) {
                                    .PRIMARY => .primary,
                                    .UNIQUE => .unique,
                                },
                            };
                        },
                    }
                }
            }
            return .{ .create_table = .{
                .name = name,
                .def = .{
                    .columns = columns,
                    .key = key,
                },
                .if_not_exists = node.if_not_exists.get(p) != null,
            } };
        },
        N.create_index => {
            return .{ .create_index = .{
                .name = node.index_name.getSource(p),
                .def = .{
                    .table_name = node.table_name.getSource(p),
                },
                .if_not_exists = node.if_not_exists.get(p) != null,
            } };
        },
        N.insert => {
            try self.noPlan(node.insert_or);
            const table_name = node.table_name.getSource(p);
            const table_def = self.database.table_defs.get(table_name) orelse
                return error.AbortPlan;
            var query = try self.planSelect(node.select_or_values, null);
            try self.resolveAllRelation(query);
            _ = try self.arrangeAllRelation(query);
            if (node.column_names.get(p)) |column_names_expr_id| {
                const column_names_expr = column_names_expr_id.get(p).column_name.get(p);
                const column_refs = try self.allocator.alloc(ColumnRef, column_names_expr.elements.len);
                for (column_refs) |*column_ref, column_ix| {
                    const column_name = column_names_expr.elements[column_ix].getSource(p);
                    column_ref.* = column_ref: {
                        for (table_def.columns) |column_def, column_def_ix| {
                            if (u.deepEqual(column_name, column_def.name))
                                break :column_ref .{ .ix = column_def_ix };
                        } else return error.NoResolve;
                    };
                }
                const column_renames = try self.allocator.alloc(?[]const u8, column_names_expr.elements.len);
                for (column_renames) |*column_rename|
                    column_rename.* = null;
                query = try self.pushRelation(.{ .project = .{
                    .input = query,
                    .column_refs = column_refs,
                    .column_renames = column_renames,
                } });
            }
            return .{ .insert = .{ .table_name = table_name, .query = query } };
        },
        N.drop => switch (node) {
            .drop_table => |drop_table| return self.planStatement(drop_table),
            .drop_index => |drop_index| return self.planStatement(drop_index),
            else => return error.NoPlan,
        },
        N.drop_table => {
            return .{ .drop_table = .{
                .name = node.table_name.getSource(p),
                .if_exists = node.if_exists.get(p) != null,
            } };
        },
        N.drop_index => {
            return .{ .drop_index = .{
                .name = node.index_name.getSource(p),
                .if_exists = node.if_exists.get(p) != null,
            } };
        },
        else => @compileError("planStatement not implemented for " ++ @typeName(@TypeOf(node))),
    }
}

fn planRelation(self: *Self, node_id: anytype) Error!RelationExprId {
    comptime {
        u.comptimeAssert(@hasDecl(@TypeOf(node_id), "is_node_id"), @TypeOf(node_id));
    }
    const p = self.parser;
    const node = node_id.get(p);
    switch (@TypeOf(node)) {
        N.select => {
            try self.noPlan(node.limit);
            const select_or_values = node.select_or_values.get(p);
            if (select_or_values.elements.len > 1) return error.NoPlan;
            const order_by_maybe = if (node.order_by.get(p)) |order_by| order_by.get(p) else null;
            return self.planSelect(select_or_values.elements[0], order_by_maybe);
        },
        N.from => return self.planRelation(node.joins),
        N.joins => {
            if (node.join_clause.get(p).elements.len > 0)
                return error.NoPlan;
            return self.planRelation(node.table_or_subquery);
        },
        N.table_or_subquery => switch (node) {
            .table_as => |table_as| return self.planRelation(table_as),
            else => return error.NoPlan,
        },
        N.table_as => {
            const table_name = node.table_name.getSource(p);
            var plan = try self.pushRelation(.{ .get_table = .{
                .table_name = table_name,
            } });
            if (node.as_table.get(p)) |as_table|
                plan = try self.pushRelation(.{ .as = .{
                    .input = plan,
                    .table_name = as_table.get(p).table_name.getSource(p),
                } });
            return plan;
        },
        else => @compileError("planRelation not implemented for " ++ @typeName(@TypeOf(node))),
    }
}

fn planSelect(self: *Self, node_id: anytype, order_by_maybe: ?N.order_by) Error!RelationExprId {
    comptime {
        u.comptimeAssert(@hasDecl(@TypeOf(node_id), "is_node_id"), @TypeOf(node_id));
    }
    const p = self.parser;
    const node = node_id.get(p);
    switch (@TypeOf(node)) {
        N.select_or_values => switch (node) {
            .select_body => |select_body| return self.planSelect(select_body, order_by_maybe),
            .values => |values| return self.planSelect(values, order_by_maybe),
        },
        N.values => {
            var plan = try self.pushRelation(.{ .none = {} });
            // TODO we should check somewhere that all the rows have the same length
            const num_columns = node.row.get(p).elements[0].get(p).exprs.get(p).expr.get(p).elements.len;
            const column_defs = try self.allocator.alloc(ColumnDef, num_columns);
            for (column_defs) |*column_def|
                column_def.* = .{
                    .id = self.nextDefId(),
                    .column_name = null,
                };
            for (node.row.get(p).elements) |row| {
                var row_plan = try self.pushRelation(.{ .some = {} });
                for (row.get(p).exprs.get(p).expr.get(p).elements) |expr, expr_ix| {
                    const scalar = try self.planScalar(expr);
                    row_plan = try self.pushRelation(.{ .map = .{
                        .input = row_plan,
                        .column_def = column_defs[expr_ix],
                        .scalar = scalar,
                    } });
                }
                plan = try self.pushRelation(.{ .unio = .{
                    .inputs = .{ plan, row_plan },
                    .all = true,
                } });
            }
            if (order_by_maybe) |order_by| {
                const column_refs = try self.allocator.alloc(ColumnRef, num_columns);
                for (column_refs) |*column_ref, i|
                    column_ref.* = .{ .def_id = column_defs[i].id };
                plan = try self.planOrderBy(plan, column_refs, order_by);
            }
            return plan;
        },
        N.select_body => {
            try self.noPlan(node.group_by);
            try self.noPlan(node.having);
            try self.noPlan(node.window);
            const from_maybe = node.from.get(p);
            var plan = if (from_maybe) |from|
                try self.planRelation(from)
            else
                try self.pushRelation(.{ .some = {} });
            var project_column_refs = u.ArrayList(ColumnRef).init(self.allocator);
            var project_column_renames = u.ArrayList(?[]const u8).init(self.allocator);
            for (node.result_column.get(p).elements) |result_column|
                switch (result_column.get(p)) {
                    .result_expr => |result_expr| {
                        const scalar_id = try self.planScalar(result_expr);
                        const scalar = self.scalar_exprs.items[scalar_id];
                        const column_rename = if (result_expr.get(p).as_column.get(p)) |as_column|
                            as_column.get(p).column_name.getSource(p)
                        else
                            null;
                        if (scalar == .column) {
                            try project_column_refs.append(scalar.column);
                            try project_column_renames.append(column_rename);
                        } else {
                            const def_id = self.nextDefId();
                            plan = try self.pushRelation(.{ .map = .{
                                .input = plan,
                                .column_def = .{
                                    .id = def_id,
                                    .column_name = null,
                                },
                                .scalar = scalar_id,
                            } });
                            try project_column_refs.append(.{ .def_id = def_id });
                            try project_column_renames.append(column_rename);
                        }
                    },
                    .star => {
                        try project_column_refs.append(.{ .ref = .{
                            .table_name = null,
                            .column_name = null,
                        } });
                        try project_column_renames.append(null);
                    },
                    .table_star => |table_star| {
                        const table_name = table_star.get(p).table_name.getSource(p);
                        try project_column_refs.append(.{ .ref = .{
                            .table_name = table_name,
                            .column_name = null,
                        } });
                        try project_column_renames.append(null);
                    },
                };
            if (node.where.get(p)) |where|
                plan = try self.pushRelation(.{
                    .filter = .{
                        .input = plan,
                        .cond = try self.planScalar(where.get(p).expr),
                    },
                });
            if (order_by_maybe) |order_by|
                plan = try self.planOrderBy(plan, project_column_refs.items, order_by);
            plan = try self.pushRelation(.{ .project = .{
                .input = plan,
                .column_refs = project_column_refs.toOwnedSlice(),
                .column_renames = project_column_renames.toOwnedSlice(),
            } });
            if (node.distinct_or_all.get(p)) |distinct_or_all| {
                if (distinct_or_all.get(p) == .DISTINCT)
                    plan = try self.pushRelation(.{ .distinct = plan });
            }
            return plan;
        },
        else => @compileError("planSelect not implemented for " ++ @typeName(@TypeOf(node))),
    }
}

fn planOrderBy(self: *Self, input: RelationExprId, input_column_refs: []const ColumnRef, order_by: N.order_by) Error!RelationExprId {
    const p = self.parser;
    var plan = input;
    var orderings = u.ArrayList(Ordering).init(self.allocator);
    for (order_by.ordering_terms.get(p).ordering_term.get(p).elements) |term_id| {
        const term = term_id.get(p);
        try self.noPlan(term.collate);
        try self.noPlan(term.nulls_first_or_last);
        const scalar_id = try self.planScalar(term.expr);
        const scalar = self.scalar_exprs.items[scalar_id];
        const column_ref = column_ref: {
            if (scalar == .value and scalar.value == .integer) {
                const ix = scalar.value.integer;
                if (ix >= 1 and ix <= input_column_refs.len)
                    break :column_ref input_column_refs[@intCast(usize, ix) - 1]
                else
                    return error.NoResolve;
            } else {
                const def_id = self.nextDefId();
                plan = try self.pushRelation(.{ .map = .{
                    .input = plan,
                    .column_def = .{
                        .id = def_id,
                        .column_name = null,
                    },
                    .scalar = scalar_id,
                } });
                break :column_ref ColumnRef{ .def_id = def_id };
            }
        };
        const desc = if (term.asc_or_desc.get(p)) |asc_or_desc|
            asc_or_desc.get(p) == .DESC
        else
            false;
        try orderings.append(.{ .column_ref = column_ref, .desc = desc });
    }
    return self.pushRelation(.{ .order_by = .{
        .input = plan,
        .orderings = orderings.toOwnedSlice(),
    } });
}

pub fn planScalar(self: *Self, node_id: anytype) Error!ScalarExprId {
    comptime {
        u.comptimeAssert(@hasDecl(@TypeOf(node_id), "is_node_id"), @TypeOf(node_id));
    }
    const p = self.parser;
    const node = node_id.get(p);
    switch (@TypeOf(node)) {
        N.result_expr => return self.planScalar(node.expr),
        N.expr => return self.planScalar(node.expr_or),
        N.expr_or, N.expr_and, N.expr_comp, N.expr_add, N.expr_mult, N.expr_bit => {
            var plan = try self.planScalar(node.left);
            for (node.right.get(p).elements) |right_expr_id| {
                plan = try self.planScalarBinary(node, plan, right_expr_id);
            }
            return plan;
        },
        N.expr_not, N.expr_unary => {
            var plan = try self.planScalar(node.expr);
            for (node.op.get(p).elements) |op|
                plan = try self.pushScalar(.{ .unary = .{ .input = plan, .op = switch (@TypeOf(node)) {
                    N.expr_not => .bool_not,
                    N.expr_unary => switch (op.get(p)) {
                        .bit_not => .bit_not,
                        .plus => .plus,
                        .minus => .minus,
                    },
                    else => unreachable,
                } } });
            return plan;
        },
        N.expr_incomp => {
            var plan = try self.planScalar(node.left);
            for (node.right.get(p).elements) |right_expr| {
                switch (right_expr.get(p)) {
                    .expr_incomp_postop => |expr_incomp_postop| {
                        for (expr_incomp_postop.get(p).op.get(p).elements) |op| {
                            plan = try self.pushScalar(.{ .binary = .{
                                .inputs = .{
                                    plan,
                                    try self.pushScalar(.{ .value = sql.Value.NULL }),
                                },
                                .op = switch (op.get(p)) {
                                    .ISNULL => .is,
                                    .NOTNULL, .NOT_NULL => .is_not,
                                },
                            } });
                        }
                    },
                    .expr_incomp_binop => |binop| plan = try self.planScalarBinary(node, plan, binop),
                    .expr_incomp_in => |expr_incomp_in| {
                        const subplan = subplan: {
                            // TODO handle correlated variables
                            switch (expr_incomp_in.get(p).right.get(p)) {
                                .exprs => |exprs| {
                                    var subplan = try self.pushRelation(.{ .none = {} });
                                    for (exprs.get(p).expr.get(p).elements) |expr|
                                        subplan = try self.pushRelation(.{ .unio = .{
                                            .inputs = .{
                                                subplan,
                                                try self.pushRelation(.{ .map = .{
                                                    .input = try self.pushRelation(.{ .some = {} }),
                                                    .column_def = .{
                                                        .id = self.nextDefId(),
                                                        .column_name = null,
                                                    },
                                                    .scalar = try self.planScalar(expr),
                                                } }),
                                            },
                                            .all = true,
                                        } });
                                    break :subplan subplan;
                                },
                                .select => |select| {
                                    break :subplan try self.planRelation(select);
                                },
                            }
                        };
                        plan = try self.pushScalar(.{ .in = .{
                            .input = plan,
                            .subplan = subplan,
                            .subplan_cache = null,
                        } });
                        if (expr_incomp_in.get(p).NOT.get(p) != null)
                            plan = try self.pushScalar(.{ .unary = .{
                                .input = plan,
                                .op = .bool_not,
                            } });
                    },
                    .expr_incomp_between => |expr_incomp_between| {
                        // https://www.sqlite.org/lang_expr.html#between
                        const start = try self.planScalar(expr_incomp_between.get(p).start);
                        const end = try self.planScalar(expr_incomp_between.get(p).end);
                        // TODO should avoid evaluating plan twice
                        plan = try self.pushScalar(.{ .binary = .{
                            .inputs = .{
                                try self.pushScalar(.{ .binary = .{
                                    .inputs = .{
                                        plan,
                                        start,
                                    },
                                    .op = .greater_than_or_equal,
                                } }),
                                try self.pushScalar(.{ .binary = .{
                                    .inputs = .{
                                        plan,
                                        end,
                                    },
                                    .op = .less_than_or_equal,
                                } }),
                            },
                            .op = .bool_and,
                        } });
                        if (expr_incomp_between.get(p).NOT.get(p) != null)
                            plan = try self.pushScalar(.{ .unary = .{
                                .input = plan,
                                .op = .bool_not,
                            } });
                    },
                }
            }
            return plan;
        },
        N.expr_atom => switch (node) {
            .subexpr => |subexpr| return self.planScalar(subexpr),
            .table_column_ref => |table_column_ref| return self.planScalar(table_column_ref),
            .column_ref => |column_ref| return self.planScalar(column_ref),
            .value => |value| return self.planScalar(value),
            else => return error.NoPlan,
        },
        N.subexpr => return self.planScalar(node.expr),
        N.table_column_ref => {
            return self.pushScalar(.{ .column = .{ .ref = .{
                .table_name = node.table_name.getSource(p),
                .column_name = node.column_name.getSource(p),
            } } });
        },
        N.column_ref => {
            return self.pushScalar(.{ .column = .{ .ref = .{
                .table_name = null,
                .column_name = node.column_name.getSource(p),
            } } });
        },
        N.value => {
            const value = switch (node) {
                .number => number: {
                    const source = node_id.getSource(p);
                    break :number if (std.fmt.parseInt(i64, source, 10)) |integer|
                        sql.Value{ .integer = integer }
                    else |_| if (std.fmt.parseFloat(f64, source)) |real|
                        sql.Value{ .real = real }
                    else |_|
                        return error.InvalidLiteral;
                },
                .string => string: {
                    const source = node_id.getSource(p);
                    var string = try u.ArrayList(u8).initCapacity(self.allocator, source.len - 2);
                    var i: usize = 1;
                    while (i < source.len - 1) : (i += 1) {
                        const char = source[i];
                        string.appendAssumeCapacity(char);
                        // The only way we can hit " in a "-string is if there is a ""-escape, so ditch one of them
                        if (char == source[0]) i += 1;
                    }
                    break :string sql.Value{ .text = string.toOwnedSlice() };
                },
                .blob => blob: {
                    const source = node_id.getSource(p);
                    var blob = try u.ArrayList(u8).initCapacity(self.allocator, (source.len - 3) * 2);
                    var i: usize = 2;
                    while (i < source.len - 1) : (i += 1) {
                        if (std.fmt.parseInt(u16, source[i .. i + 1], 16)) |num|
                            blob.appendSliceAssumeCapacity(&@bitCast([2]u8, num))
                        else |_|
                            return error.InvalidLiteral;
                    }
                    break :blob sql.Value{ .blob = blob.toOwnedSlice() };
                },
                .NULL => sql.Value{ .nul = {} },
            };
            return self.pushScalar(.{ .value = value });
        },
        else => @compileError("planScalar not implemented for " ++ @typeName(@TypeOf(node))),
    }
}

fn planScalarBinary(self: *Self, parent: anytype, left: ScalarExprId, right_expr_id: anytype) Error!ScalarExprId {
    const p = self.parser;
    const right_expr = right_expr_id.get(p);
    const right = try self.planScalar(right_expr.right);
    return try self.pushScalar(.{ .binary = .{
        .inputs = .{ left, right },
        .op = switch (@TypeOf(parent)) {
            N.expr_or => .bool_or,
            N.expr_and => .bool_and,
            N.expr_incomp => switch (right_expr.op.get(p)) {
                .equal => .equal,
                .double_equal => .double_equal,
                .not_equal => .not_equal,
                .IS_DISTINCT_FROM => .is_distinct_from,
                .IS_NOT_DISTINCT_FROM => .is_not_distinct_from,
                .IS_NOT => .is_not,
                .IS => .is,
                .MATCH => .match,
                .LIKE => .like,
                .REGEXP => .regexp,
                .GLOB => .glob,
                .NOT_MATCH => .not_match,
                .NOT_LIKE => .not_like,
                .NOT_REGEXP => .not_regexp,
                .NOT_GLOB => .not_glob,
            },
            N.expr_comp => switch (right_expr.op.get(p)) {
                .less_than => .less_than,
                .greater_than => .greater_than,
                .less_than_or_equal => .less_than_or_equal,
                .greater_than_or_equal => .greater_than_or_equal,
            },
            N.expr_bit => switch (right_expr.op.get(p)) {
                .shift_left => .shift_left,
                .shift_right => .shift_right,
                .bit_and => .bit_and,
                .bit_or => .bit_or,
            },
            N.expr_add => switch (right_expr.op.get(p)) {
                .plus => .plus,
                .minus => .minus,
            },
            N.expr_mult => switch (right_expr.op.get(p)) {
                .star => .star,
                .forward_slash => .forward_slash,
                .percent => .percent,
            },
            else => unreachable,
        },
    } });
}

pub fn planType(self: *Self, node_id: NodeId("typ")) !sql.Type {
    const p = self.parser;
    const name = node_id.get(p).name.getSource(p);
    // TODO fix case comparison
    if (u.deepEqual(name, "INTEGER"))
        return .integer;
    if (u.deepEqual(name, "FLOAT"))
        return .real;
    if (u.deepEqual(name, "VARCHAR") or
        u.deepEqual(name, "TEXT"))
        return .text;
    return error.BadType;
}

fn noPlan(self: *Self, node_id: anytype) Error!void {
    const p = self.parser;
    const node = node_id.get(p);
    if (node != null) return error.NoPlan;
}

fn resolveAllRelation(self: *Self, relation_expr_id: RelationExprId) Error!void {
    const relation = &self.relation_exprs.items[relation_expr_id];
    switch (relation.*) {
        .none, .some => {},
        .map => |map| {
            try self.resolveAllRelation(map.input);
            try self.resolveAllScalar(map.scalar, map.input);
        },
        .filter => |filter| {
            try self.resolveAllRelation(filter.input);
            try self.resolveAllScalar(filter.cond, filter.input);
        },
        .project => |*project| {
            try self.resolveAllRelation(project.input);
            var column_defs = u.ArrayList(ColumnDef).init(self.allocator);
            var new_column_refs = u.ArrayList(ColumnRef).init(self.allocator);
            for (project.column_refs) |column_ref, column_ref_ix| {
                const start_ix = column_defs.items.len;
                try self.resolveRefMany(column_ref, project.input, &new_column_refs, &column_defs);
                if (project.column_renames[column_ref_ix]) |column_rename| {
                    for (column_defs.items[start_ix..]) |*column_def|
                        column_def.column_name = column_rename;
                }
            }
            project.column_refs = new_column_refs.toOwnedSlice();
            project.column_defs = column_defs.toOwnedSlice();
        },
        .unio => |unio| {
            try self.resolveAllRelation(unio.inputs[0]);
            try self.resolveAllRelation(unio.inputs[1]);
        },
        .get_table => |*get_table| {
            const table_def = self.database.table_defs.get(get_table.table_name) orelse
                return error.AbortPlan;
            const column_defs = try self.allocator.alloc(ColumnDef, table_def.columns.len);
            for (column_defs) |*column_def, i|
                column_def.* = .{
                    .id = self.nextDefId(),
                    .column_name = table_def.columns[i].name,
                };
            get_table.column_defs = column_defs;
        },
        .distinct => |distinct| {
            try self.resolveAllRelation(distinct);
        },
        .order_by => |order_by| {
            try self.resolveAllRelation(order_by.input);
            for (order_by.orderings) |*ordering|
                ordering.column_ref = try self.resolveRefOne(ordering.column_ref, order_by.input);
        },
        .as => |as| {
            try self.resolveAllRelation(as.input);
        },
    }
}

fn resolveAllScalar(self: *Self, scalar_expr_id: ScalarExprId, input: RelationExprId) Error!void {
    const scalar_expr = &self.scalar_exprs.items[scalar_expr_id];
    switch (scalar_expr.*) {
        .value => {},
        .column => |*column_ref| {
            column_ref.* = try self.resolveRefOne(column_ref.*, input);
        },
        .unary => |unary| {
            try self.resolveAllScalar(unary.input, input);
        },
        .binary => |binary| {
            try self.resolveAllScalar(binary.inputs[0], input);
            try self.resolveAllScalar(binary.inputs[1], input);
        },
        .in => |in| {
            try self.resolveAllScalar(in.input, input);
            try self.resolveAllRelation(in.subplan);
        },
    }
}

fn resolveRefOne(self: *Self, column_ref: ColumnRef, input: RelationExprId) Error!ColumnRef {
    var out_column_refs = u.ArrayList(ColumnRef).init(self.allocator);
    var out_column_defs = u.ArrayList(ColumnDef).init(self.allocator);
    try self.resolveRefMany(column_ref, input, &out_column_refs, &out_column_defs);
    return switch (out_column_refs.items.len) {
        0 => error.NoResolve,
        1 => out_column_refs.items[0],
        else => error.MultipleResolve,
    };
}

fn resolveRefMany(
    self: *Self,
    column_ref: ColumnRef,
    input_id: RelationExprId,
    out_column_refs: *u.ArrayList(ColumnRef),
    out_column_defs: *u.ArrayList(ColumnDef),
) Error!void {
    const input = self.relation_exprs.items[input_id];
    switch (input) {
        .none, .some => {},
        .map => |map| {
            try self.resolveRefMany(column_ref, map.input, out_column_refs, out_column_defs);
            if (column_ref == .ref and
                column_ref.ref.column_name == null)
                return;
            try self.resolveRefAgainst(column_ref, map.column_def, out_column_refs, out_column_defs);
        },
        .filter => |filter| {
            try self.resolveRefMany(column_ref, filter.input, out_column_refs, out_column_defs);
        },
        .project => |project| {
            for (project.column_defs.?) |column_def|
                try self.resolveRefAgainst(column_ref, column_def, out_column_refs, out_column_defs);
        },
        .unio => |unio| {
            try self.resolveRefMany(column_ref, unio.inputs[0], out_column_refs, out_column_defs);
            // We only resolve against the left side of the union.
        },
        .get_table => |get_table| {
            if (column_ref == .ref)
                if (column_ref.ref.table_name) |table_name|
                    if (!u.deepEqual(table_name, get_table.table_name))
                        return;
            for (get_table.column_defs.?) |column_def|
                try self.resolveRefAgainst(column_ref, column_def, out_column_refs, out_column_defs);
        },
        .distinct => |distinct| {
            try self.resolveRefMany(column_ref, distinct, out_column_refs, out_column_defs);
        },
        .order_by => |order_by| {
            try self.resolveRefMany(column_ref, order_by.input, out_column_refs, out_column_defs);
        },
        .as => |as| {
            if (column_ref == .ref) {
                if (column_ref.ref.table_name) |table_name|
                    if (!u.deepEqual(table_name, as.table_name))
                        return;
                try self.resolveRefMany(.{
                    .ref = .{
                        .table_name = null,
                        .column_name = column_ref.ref.column_name,
                    },
                }, as.input, out_column_refs, out_column_defs);
            } else {
                try self.resolveRefMany(column_ref, as.input, out_column_refs, out_column_defs);
            }
        },
    }
}

fn resolveRefAgainst(
    self: *Self,
    column_ref: ColumnRef,
    column_def: ColumnDef,
    out_column_refs: *u.ArrayList(ColumnRef),
    out_column_defs: *u.ArrayList(ColumnDef),
) Error!void {
    const is_match = switch (column_ref) {
        .ref => |ref| ref.column_name == null or u.deepEqual(ref.column_name, column_def.column_name),
        .def_id => |def_id| def_id == column_def.id,
        .ix => unreachable,
    };
    if (is_match) {
        try out_column_refs.append(.{ .def_id = column_def.id });
        try out_column_defs.append(.{ .id = self.nextDefId(), .column_name = column_def.column_name });
    }
}

fn arrangeAllRelation(self: *Self, relation_expr_id: RelationExprId) Error![]const ColumnDef {
    const relation = &self.relation_exprs.items[relation_expr_id];
    switch (relation.*) {
        .none, .some => return &.{},
        .map => |map| {
            const input = try self.arrangeAllRelation(map.input);
            try self.arrangeAllScalar(map.scalar, input);
            return std.mem.concat(self.allocator, ColumnDef, &.{
                input,
                &.{map.column_def},
            });
        },
        .filter => |filter| {
            const input = try self.arrangeAllRelation(filter.input);
            try self.arrangeAllScalar(filter.cond, input);
            return input;
        },
        .project => |project| {
            const input = try self.arrangeAllRelation(project.input);
            for (project.column_refs) |*column_ref|
                column_ref.* = try self.arrangeRefAgainst(column_ref.*, input);
            return project.column_defs.?;
        },
        .unio => |unio| {
            const input = self.arrangeAllRelation(unio.inputs[0]);
            _ = try self.arrangeAllRelation(unio.inputs[1]);
            return input;
        },
        .get_table => |get_table| {
            return get_table.column_defs.?;
        },
        .distinct => |distinct| {
            return try self.arrangeAllRelation(distinct);
        },
        .order_by => |order_by| {
            const input = try self.arrangeAllRelation(order_by.input);
            for (order_by.orderings) |*ordering|
                ordering.column_ref = try self.arrangeRefAgainst(ordering.column_ref, input);
            return input;
        },
        .as => |as| {
            return try self.arrangeAllRelation(as.input);
        },
    }
}

fn arrangeAllScalar(self: *Self, scalar_expr_id: ScalarExprId, input: []const ColumnDef) Error!void {
    const scalar_expr = &self.scalar_exprs.items[scalar_expr_id];
    switch (scalar_expr.*) {
        .value => {},
        .column => |*column_ref| {
            column_ref.* = try self.arrangeRefAgainst(column_ref.*, input);
        },
        .unary => |unary| {
            try self.arrangeAllScalar(unary.input, input);
        },
        .binary => |binary| {
            try self.arrangeAllScalar(binary.inputs[0], input);
            try self.arrangeAllScalar(binary.inputs[1], input);
        },
        .in => |in| {
            try self.arrangeAllScalar(in.input, input);
            _ = try self.arrangeAllRelation(in.subplan);
        },
    }
}

fn arrangeRefAgainst(self: *Self, column_ref: ColumnRef, input: []const ColumnDef) Error!ColumnRef {
    _ = self;
    if (column_ref == .ix)
        // Sometimes scalar_exprs are shared, so we can visit the same column_ref twice
        return column_ref;
    for (input) |column_def, ix|
        if (column_ref.def_id == column_def.id)
            return ColumnRef{ .ix = ix };
    return error.BadArrange;
}
