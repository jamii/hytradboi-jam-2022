const std = @import("std");
const sql = @import("../sql.zig");
const u = sql.util;

const Self = @This();
arena: *u.ArenaAllocator,
allocator: u.Allocator,
planner: sql.Planner,
database: *sql.Database,
juice: usize,

pub const Error = error{
    OutOfMemory,
    OutOfJuice,
    TypeError,
    NoEval,
    AbortEval,
    BadColumn,
};

pub fn init(
    arena: *u.ArenaAllocator,
    planner: sql.Planner,
    database: *sql.Database,
    juice: usize,
) Self {
    const allocator = arena.allocator();
    return Self{
        .arena = arena,
        .allocator = allocator,
        .planner = planner,
        .database = database,
        .juice = juice,
    };
}

pub const Relation = u.ArrayList(Row);
pub const Row = u.ArrayList(Scalar);
pub const Scalar = sql.Value; // TODO move from sql to here

pub fn evalStatement(self: *Self, statement_expr: sql.Planner.StatementExpr) Error!Relation {
    const empty_relation = Relation.init(self.allocator);
    switch (statement_expr) {
        .select => |select| return self.evalRelation(select),
        .create_table => |create_table| {
            const exists = self.database.table_defs.contains(create_table.name);
            if (exists)
                return if (create_table.if_not_exists) empty_relation else error.AbortEval
            else {
                try self.database.table_defs.put(
                    try u.deepClone(self.database.allocator, create_table.name),
                    try u.deepClone(self.database.allocator, create_table.def),
                );
                try self.database.tables.put(
                    try u.deepClone(self.database.allocator, create_table.name),
                    sql.Table.init(self.database.allocator),
                );
                return empty_relation;
            }
        },
        .create_index => |create_index| {
            const exists = self.database.index_defs.contains(create_index.name);
            if (exists)
                return if (create_index.if_not_exists) empty_relation else error.AbortEval
            else {
                try self.database.index_defs.put(
                    try u.deepClone(self.database.allocator, create_index.name),
                    try u.deepClone(self.database.allocator, create_index.def),
                );
                return empty_relation;
            }
        },
        .insert => |insert| {
            const table = self.database.tables.getPtr(insert.table_name).?;
            const rows = try self.evalRelation(insert.query);
            for (rows.items) |row|
                // unique keys are not tested in slt
                try table.append(try u.deepClone(self.database.allocator, row.items));
            return empty_relation;
        },
        .drop_table => |drop_table| {
            const exists = self.database.table_defs.contains(drop_table.name);
            if (!exists)
                return if (drop_table.if_exists) empty_relation else error.AbortEval
            else {
                _ = self.database.table_defs.remove(drop_table.name);
                _ = self.database.tables.remove(drop_table.name);
                var to_remove = u.ArrayList(sql.IndexName).init(self.allocator);
                var iter = self.database.index_defs.iterator();
                while (iter.next()) |entry|
                    if (u.deepEqual(drop_table.name, entry.value_ptr.table_name))
                        try to_remove.append(entry.key_ptr.*);
                for (to_remove.items) |index_name|
                    _ = self.database.index_defs.remove(index_name);
                return empty_relation;
            }
        },
        .drop_index => |drop_index| {
            const exists = self.database.index_defs.contains(drop_index.name);
            if (!exists)
                return if (drop_index.if_exists) empty_relation else error.AbortEval
            else {
                _ = self.database.index_defs.remove(drop_index.name);
                return empty_relation;
            }
        },
        .noop => return empty_relation,
    }
}

fn evalRelation(self: *Self, relation_expr_id: sql.Planner.RelationExprId) Error!Relation {
    const relation_expr = self.planner.relation_exprs.items[relation_expr_id];
    var output = Relation.init(self.allocator);
    switch (relation_expr) {
        .none => {},
        .some => try output.append(Row.init(self.allocator)),
        .map => |map| {
            const input = try self.evalRelation(map.input);
            for (input.items) |*input_row| {
                try self.useJuice();
                const value = try self.evalScalar(map.scalar, input_row.*);
                try input_row.append(value);
            }
            output = input;
        },
        .filter => |filter| {
            var input = try self.evalRelation(filter.input);
            var i: usize = 0;
            for (input.items) |input_row| {
                try self.useJuice();
                const cond = try self.evalScalar(filter.cond, input_row);
                if (cond != .nul and try cond.toBool()) {
                    input.items[i] = input_row;
                    i += 1;
                }
            }
            input.shrinkRetainingCapacity(i);
            output = input;
        },
        .project => |project| {
            const input = try self.evalRelation(project.input);
            for (input.items) |*input_row| {
                try self.useJuice();
                var output_row = try Row.initCapacity(self.allocator, project.column_refs.len);
                for (project.column_refs) |column_ref|
                    output_row.appendAssumeCapacity(input_row.items[column_ref.ix]);
                input_row.* = output_row;
            }
            output = input;
        },
        .unio => |unio| {
            var left = try self.evalRelation(unio.inputs[0]);
            const right = try self.evalRelation(unio.inputs[1]);
            if (unio.all) {
                try left.appendSlice(right.items);
            } else {
                var set = u.DeepHashSet(Row).init(self.allocator);
                for (left.items) |row| {
                    try self.useJuice();
                    try set.put(row, {});
                }
                for (right.items) |row| {
                    try self.useJuice();
                    try set.put(row, {});
                }
                left.shrinkRetainingCapacity(0);
                var iter = set.keyIterator();
                while (iter.next()) |row| try left.append(row.*);
            }
            output = left;
        },
        .get_table => |get_table| {
            const table = self.database.tables.get(get_table.table_name) orelse
                return error.AbortEval;
            for (table.items) |input_row| {
                try self.useJuice();
                var output_row = try Row.initCapacity(self.allocator, input_row.len);
                output_row.appendSliceAssumeCapacity(input_row);
                try output.append(output_row);
            }
        },
        .distinct => |distinct| {
            var input = try self.evalRelation(distinct);
            var set = u.DeepHashSet(Row).init(self.allocator);
            for (input.items) |row| {
                try self.useJuice();
                try set.put(row, {});
            }
            input.shrinkRetainingCapacity(0);
            var iter = set.keyIterator();
            while (iter.next()) |row| try input.append(row.*);
            output = input;
        },
        .order_by => |order_by| {
            const input = try self.evalRelation(order_by.input);
            std.sort.sort(Row, input.items, order_by.orderings, (struct {
                fn lessThan(orderings: []sql.Planner.Ordering, a: Row, b: Row) bool {
                    for (orderings) |ordering|
                        switch (Scalar.order(a.items[ordering.column_ref.ix], b.items[ordering.column_ref.ix])) {
                            .eq => continue,
                            .lt => return !ordering.desc,
                            .gt => return ordering.desc,
                        };
                    return false;
                }
            }).lessThan);
            return input;
        },
        .as => |as| return self.evalRelation(as.input),
    }
    //u.dump(.{ relation_expr, output });
    return output;
}

fn evalScalar(self: *Self, scalar_expr_id: sql.Planner.ScalarExprId, env: Row) Error!Scalar {
    const scalar_expr = &self.planner.scalar_exprs.items[scalar_expr_id];
    switch (scalar_expr.*) {
        .value => |value| return value,
        .column => |column| {
            return if (column.ix >= env.items.len)
                error.BadColumn
            else
                env.items[column.ix];
        },
        .unary => |unary| {
            const input = try self.evalScalar(unary.input, env);
            switch (unary.op) {
                .is_null, .is_not_null => {},
                else => if (input == .nul) return Scalar.NULL,
            }
            switch (unary.op) {
                .is_null => return Scalar.fromBool(input == .nul),
                .is_not_null => return Scalar.fromBool(input != .nul),
                .bool_not => return Scalar.fromBool(!(try input.toBool())),
                .bit_not => return error.NoEval,
                .plus => {
                    // In sqlite you can do `+ 'foo'` and get `'foo'`
                    return input;
                },
                .minus => {
                    return switch (input) {
                        .integer => |integer| Scalar{ .integer = -integer },
                        .real => |real| Scalar{ .real = -real },
                        else => error.TypeError,
                    };
                },
            }
        },
        .binary => |binary| {
            var left = try self.evalScalar(binary.inputs[0], env);
            var right = try self.evalScalar(binary.inputs[1], env);
            switch (binary.op) {
                .is, .is_not => {},
                else => {
                    if (left == .nul) return Scalar.NULL;
                    if (right == .nul) return Scalar.NULL;
                },
            }
            return switch (binary.op) {
                .bool_and => return Scalar.fromBool(try left.toBool() and try right.toBool()),
                .bool_or => return Scalar.fromBool(try left.toBool() or try right.toBool()),
                .equal, .is => return Scalar.fromBool(u.deepEqual(left, right)),
                .not_equal, .is_not => return Scalar.fromBool(!u.deepEqual(left, right)),
                .less_than => return Scalar.fromBool(Scalar.order(left, right) == .lt),
                .greater_than => return Scalar.fromBool(Scalar.order(left, right) == .gt),
                .less_than_or_equal => return Scalar.fromBool(Scalar.order(left, right) != .gt),
                .greater_than_or_equal => return Scalar.fromBool(Scalar.order(left, right) != .lt),
                .plus, .minus, .star, .forward_slash => {
                    if (!left.isNumeric()) return error.TypeError;
                    if (!right.isNumeric()) return error.TypeError;
                    if (left == .real and right == .integer)
                        right = right.promoteToReal();
                    if (right == .real and left == .integer)
                        left = left.promoteToReal();
                    return if (left == .real and right == .real)
                        switch (binary.op) {
                            .plus => Scalar{ .real = left.real + right.real },
                            .minus => Scalar{ .real = left.real - right.real },
                            .star => Scalar{ .real = left.real * right.real },
                            .forward_slash => if (right.real == 0)
                                Scalar.NULL
                            else
                                Scalar{ .real = left.real / right.real },
                            else => unreachable,
                        }
                    else switch (binary.op) {
                        .plus => Scalar{ .integer = left.integer + right.integer },
                        .minus => Scalar{ .integer = left.integer - right.integer },
                        .star => Scalar{ .integer = left.integer * right.integer },
                        .forward_slash => if (right.integer == 0)
                            Scalar.NULL
                        else
                            Scalar{ .integer = @divTrunc(left.integer, right.integer) },
                        else => unreachable,
                    };
                },
                else => error.NoEval,
            };
        },
        .in => |*in| {
            const input = try self.evalScalar(in.input, env);
            const subplan = in.subplan_cache orelse try self.evalRelation(in.subplan);
            in.subplan_cache = subplan;
            var input_in_subplan = false;

            if (input == .nul)
                return if (subplan.items.len == 0) Scalar.FALSE else Scalar.NULL;
            for (subplan.items) |row| {
                if (u.deepEqual(input, row.items[0]))
                    input_in_subplan = true;
            }
            if (!input_in_subplan)
                for (subplan.items) |row|
                    if (row.items[0] == .nul)
                        return Scalar.NULL;
            return Scalar.fromBool(input_in_subplan);
        },
    }
}

fn useJuice(self: *Self) !void {
    if (self.juice == 0) return error.OutOfJuice;
    self.juice -= 1;
}
