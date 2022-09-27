const std = @import("std");
const sql = @import("../sql.zig");
const u = sql.util;

const Self = @This();
const source = @embedFile("../../deps/sql-2016.bnf");
allocator: u.Allocator,
nodes: u.ArrayList(Node),
name_to_node: u.DeepHashMap([]const u8, NodeId),
pos: usize,

query_specification: ?NodeId,
sql_procedure_statement: ?NodeId,
regular_identifier: ?NodeId,

reserved_words: std.StringHashMap(void),

pub const NodeId = usize;
pub const Node = union(enum) {
    def_name: struct {
        name: []const u8,
        body: NodeId,
        may_contain_whitespace: bool,
    },
    ref_name: struct {
        name: []const u8,
        id: ?NodeId,
    },
    literal: []const u8,
    either: [2]NodeId,
    both: [2]NodeId,
    optional: NodeId,

    // hardcoded tokenizers
    space,
    newline,
    whitespace,
    identifier_start,
    identifier_extend,
    unicode_escape_character,
    non_quote_character,
    non_double_quote_character,
    escaped_character,
    non_escaped_character,

    // for more obscure syntax that we don't care about, just give up
    fail,
};
pub const Error = error{OutOfMemory};

pub fn init(allocator: u.Allocator) Self {
    return Self{
        .allocator = allocator,
        .nodes = u.ArrayList(Node).init(allocator),
        .name_to_node = u.DeepHashMap([]const u8, NodeId).init(allocator),
        .pos = 0,
        .query_specification = null,
        .sql_procedure_statement = null,
        .regular_identifier = null,
        .reserved_words = std.StringHashMap(void).init(allocator),
    };
}

pub fn assert(self: *Self, cond: bool) void {
    u.assert(cond, .{source[self.pos..]});
}

pub fn splitAt(self: *Self, needle: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, source[self.pos..], needle)) |offset| {
        const result = source[self.pos .. self.pos + offset];
        self.pos += offset + needle.len;
        return result;
    } else return null;
}

pub fn consume(self: *Self, needle: []const u8) void {
    self.assert(self.tryConsume(needle));
}

pub fn tryConsume(self: *Self, needle: []const u8) bool {
    if (std.mem.startsWith(u8, source[self.pos..], needle)) {
        self.pos += needle.len;
        return true;
    } else {
        return false;
    }
}

pub fn discardSpace(self: *Self) void {
    while (self.pos < source.len) {
        switch (source[self.pos]) {
            ' ' => self.pos += 1,
            else => break,
        }
    }
}

pub fn discardSpaceAndNewline(self: *Self) void {
    while (self.pos < source.len) {
        switch (source[self.pos]) {
            ' ', '\n' => self.pos += 1,
            else => break,
        }
    }
}

pub fn pushNode(self: *Self, node: Node) Error!NodeId {
    const id = self.nodes.items.len;
    try self.nodes.append(node);
    return id;
}

pub fn parseDefs(self: *Self) Error!void {
    while (self.pos < source.len) {
        self.discardSpaceAndNewline();
        if (self.pos == source.len) break;
        switch (source[self.pos]) {
            '0'...'9' => {
                // Skip comments
                _ = self.splitAt("Format\n");
            },
            else => {},
        }
        _ = try self.parseDef();
    }

    for (self.nodes.items) |node, id| {
        if (node == .def_name)
            try self.name_to_node.put(node.def_name.name, id);
    }
    for (self.nodes.items) |*node| {
        if (node.* == .ref_name)
            node.ref_name.id = self.name_to_node.get(node.ref_name.name) orelse u.panic("What are \"{}\"", .{std.zig.fmtEscapes(node.ref_name.name)});
    }

    self.query_specification = self.name_to_node.get("query specification").?;
    self.sql_procedure_statement = self.name_to_node.get("SQL procedure statement").?;
    self.regular_identifier = self.name_to_node.get("regular identifier").?;

    {
        var def_count: usize = 0;
        for (self.nodes.items) |node| {
            if (node == .def_name and !std.mem.startsWith(u8, node.def_name.name, "one_or_more"))
                def_count += 1;
        }
        u.assert(def_count == 1719, def_count);
    }

    {
        var iter = std.mem.tokenize(u8, reserved_words_raw, " |\n");
        while (iter.next()) |word|
            try self.reserved_words.put(word, {});
    }
}

fn parseDef(self: *Self) Error!NodeId {
    const name = try self.parseName();
    _ = self.splitAt("::=");
    self.discardSpaceAndNewline();
    const body = try self.parseDefBody(name);
    // > NOTE 19 - White space is typically used to separate <nondelimiter token>s from one another in SQL text always permitted between two tokens in SQL text.
    const may_contain_whitespace =
        !(u.deepEqual(name, "regular identifier") or
        u.deepEqual(name, "key word") or
        u.deepEqual(name, "unsigned numeric literal") or
        u.deepEqual(name, "national character string literal") or
        u.deepEqual(name, "binary string literal") or
        u.deepEqual(name, "large object length token") or
        u.deepEqual(name, "Unicode delimited identifier") or
        u.deepEqual(name, "Unicode character string literal") or
        u.deepEqual(name, "SQL language identifier"));
    return self.pushNode(.{ .def_name = .{ .name = name, .body = body, .may_contain_whitespace = may_contain_whitespace } });
}

fn parseName(self: *Self) ![]const u8 {
    self.consume("<");
    const raw_name = self.splitAt(">").?;
    // Sometimes the grammar line-wraps in the middle of a name :|
    var name = u.ArrayList(u8).init(self.allocator);
    var iter = std.mem.tokenize(u8, raw_name, " \n");
    while (iter.next()) |part| {
        if (name.items.len > 0)
            try name.append(' ');
        try name.appendSlice(part);
    }
    return name.toOwnedSlice();
}

fn parseDefBody(self: *Self, name: []const u8) Error!NodeId {
    // We have to special-case many rules that are otherwise unparseable
    const maybe_node =
        if (u.deepEqual(name, "left bracket"))
        Node{ .literal = "[" }
    else if (u.deepEqual(name, "right bracket"))
        Node{ .literal = "]" }
    else if (u.deepEqual(name, "less than operator"))
        Node{ .literal = "<" }
    else if (u.deepEqual(name, "less than or equals operator"))
        Node{ .literal = "<=" }
    else if (u.deepEqual(name, "not equals operator"))
        Node{ .literal = "<>" }
    else if (u.deepEqual(name, "left brace"))
        Node{ .literal = "{" }
    else if (u.deepEqual(name, "left brace minus"))
        Node{ .literal = "{-" }
    else if (u.deepEqual(name, "space"))
        Node{ .space = {} }
    else if (u.deepEqual(name, "newline"))
        Node{ .newline = {} }
    else if (u.deepEqual(name, "white space"))
        Node{ .whitespace = {} }
    else if (u.deepEqual(name, "identifier start"))
        Node{ .identifier_start = {} }
    else if (u.deepEqual(name, "identifier extend"))
        Node{ .identifier_extend = {} }
    else if (u.deepEqual(name, "Unicode escape character"))
        Node{ .unicode_escape_character = {} }
    else if (u.deepEqual(name, "nonquote character"))
        Node{ .non_quote_character = {} }
    else if (u.deepEqual(name, "nondoublequote character"))
        Node{ .non_double_quote_character = {} }
    else if (u.deepEqual(name, "escaped character"))
        Node{ .escaped_character = {} }
    else if (u.deepEqual(name, "non-escaped character"))
        Node{ .non_escaped_character = {} }
    else if (std.mem.indexOf(u8, name, "JSON") != null or
        std.mem.indexOf(u8, name, "implementation-defined") != null or
        std.mem.indexOf(u8, name, "host") != null or
        std.mem.indexOf(u8, name, "embedded") != null)
        Node{ .fail = {} }
    else
        null;
    if (maybe_node) |node| {
        // Go to start of next def
        _ = self.splitAt("\n<");
        self.pos -= "\n<".len;
        return self.pushNode(node);
    } else {
        if (self.tryConsume("!!"))
            // We should have special-cased any rule that contains only comments
            self.assert(false);

        return self.parseExpr(.all);
    }
}

fn parseExpr(self: *Self, level: enum { all, all_but_either }) Error!NodeId {
    var node = try self.parseAtom();

    while (true) {
        self.discardSpace();
        if (self.tryConsume("\n")) {
            if (self.pos < source.len and source[self.pos] != ' ' and source[self.pos] != '\n') {
                // This is the start of a new def (because it isn't indented)
                self.pos -= "\n".len;
                break;
            }
        } else if (self.tryConsume("...")) {

            // anon ::= node [ anon ]
            const name = try std.fmt.allocPrint(self.allocator, "one_or_more_{}", .{self.nodes.items.len});
            const anon_ref = try self.pushNode(.{ .ref_name = .{
                .name = name,
                .id = null,
            } });
            const anon_ref_optional = try self.pushNode(.{ .optional = anon_ref });
            const anon_body = try self.pushNode(.{ .both = .{ node, anon_ref_optional } });
            const anon_def = try self.pushNode(.{ .def_name = .{
                .name = name,
                .body = anon_body,
                .may_contain_whitespace = true,
            } });
            _ = anon_def;

            // node = node [ anon ]
            node = anon_body;
        } else if (self.tryConsume("|")) {
            switch (level) {
                .all => {
                    self.discardSpaceAndNewline();
                    const right = try self.parseExpr(.all_but_either);
                    node = try self.pushNode(.{ .either = .{ node, right } });
                },
                .all_but_either => {
                    self.pos -= "|".len;
                    break;
                },
            }
        } else if (self.tryConsume("!!")) {
            // Discard comment
            _ = self.splitAt("\n") orelse "";
        } else if (self.pos >= source.len or source[self.pos] == ']' or source[self.pos] == '}') {
            break;
        } else {
            const right = try self.parseAtom();
            node = try self.pushNode(.{ .both = .{ node, right } });
        }
    }

    return node;
}

fn parseAtom(self: *Self) Error!NodeId {
    return switch (source[self.pos]) {
        '<' => try self.parseRefName(),
        '[' => try self.parseOptional(),
        '{' => try self.parseGroup(),
        else => try self.parseLiteral(),
    };
}

fn parseRefName(self: *Self) Error!NodeId {
    const name = try self.parseName();
    return self.pushNode(.{ .ref_name = .{
        .name = name,
        .id = null,
    } });
}

fn parseLiteral(self: *Self) Error!NodeId {
    const start = self.pos;
    while (self.pos < source.len) {
        switch (source[self.pos]) {
            ' ', '\n' => break,
            else => self.pos += 1,
        }
    }
    const literal = try std.ascii.allocLowerString(self.allocator, source[start..self.pos]);
    return self.pushNode(.{ .literal = literal });
}

fn parseOptional(self: *Self) Error!NodeId {
    self.consume("[");
    self.discardSpaceAndNewline();
    const body = try self.parseExpr(.all);
    self.discardSpaceAndNewline();
    self.consume("]");
    return self.pushNode(.{ .optional = body });
}

fn parseGroup(self: *Self) Error!NodeId {
    self.consume("{");
    self.discardSpaceAndNewline();
    const body = try self.parseExpr(.all);
    self.discardSpaceAndNewline();
    self.consume("}");
    return body;
}

const reserved_words_raw =
    \\  | ABS | ACOS | ALL | ALLOCATE | ALTER | AND | ANY | ARE | ARRAY | ARRAY_AGG
    \\  | ARRAY_MAX_CARDINALITY | AS | ASENSITIVE | ASIN | ASYMMETRIC | AT | ATAN
    \\  | ATOMIC | AUTHORIZATION | AVG
    \\  | BEGIN | BEGIN_FRAME | BEGIN_PARTITION | BETWEEN | BIGINT | BINARY
    \\  | BLOB | BOOLEAN | BOTH | BY
    \\  | CALL | CALLED | CARDINALITY | CASCADED | CASE | CAST | CEIL | CEILING
    \\  | CHAR | CHAR_LENGTH | CHARACTER | CHARACTER_LENGTH | CHECK | CLASSIFIER | CLOB
    \\  | CLOSE | COALESCE | COLLATE | COLLECT | COLUMN | COMMIT | CONDITION | CONNECT
    \\  | CONSTRAINT | CONTAINS | CONVERT | COPY | CORR | CORRESPONDING | COS | COSH
    \\  | COUNT | COVAR_POP | COVAR_SAMP | CREATE | CROSS | CUBE | CUME_DIST | CURRENT
    \\  | CURRENT_CATALOG | CURRENT_DATE | CURRENT_DEFAULT_TRANSFORM_GROUP
    \\  | CURRENT_PATH | CURRENT_ROLE | CURRENT_ROW | CURRENT_SCHEMA | CURRENT_TIME
    \\  | CURRENT_TIMESTAMP | CURRENT_PATH | CURRENT_ROLE | CURRENT_TRANSFORM_GROUP_FOR_TYPE
    \\  | CURRENT_USER | CURSOR | CYCLE
    \\  | DATE | DAY | DEALLOCATE | DEC | DECIMAL | DECFLOAT | DECLARE | DEFAULT | DEFINE
    \\  | DELETE | DENSE_RANK | DEREF | DESCRIBE | DETERMINISTIC | DISCONNECT | DISTINCT
    \\  | DOUBLE | DROP | DYNAMIC
    \\  | EACH | ELEMENT | ELSE | EMPTY | END | END_FRAME | END_PARTITION | END-EXEC
    \\  | EQUALS | ESCAPE | EVERY | EXCEPT | EXEC | EXECUTE | EXISTS | EXP
    \\  | EXTERNAL | EXTRACT
    \\  | FALSE | FETCH | FILTER | FIRST_VALUE | FLOAT | FLOOR | FOR | FOREIGN
    \\  | FRAME_ROW | FREE | FROM | FULL | FUNCTION | FUSION
    \\  | GET | GLOBAL | GRANT | GROUP | GROUPING | GROUPS
    \\  | HAVING | HOLD | HOUR
    \\  | IDENTITY | IN | INDICATOR | INITIAL | INNER | INOUT | INSENSITIVE | INSERT
    \\  | INT | INTEGER | INTERSECT | INTERSECTION | INTERVAL | INTO | IS
    \\  | JOIN | JSON_ARRAY | JSON_ARRAYAGG | JSON_EXISTS | JSON_OBJECT
    \\  | JSON_OBJECTAGG | JSON_QUERY | JSON_TABLE | JSON_TABLE_PRIMITIVE | JSON_VALUE
    \\  | LAG | LANGUAGE | LARGE | LAST_VALUE | LATERAL | LEAD | LEADING | LEFT | LIKE
    \\  | LIKE_REGEX | LISTAGG | LN | LOCAL | LOCALTIME | LOCALTIMESTAMP | LOG | LOG10 | LOWER
    \\  | MATCH | MATCH_NUMBER | MATCH_RECOGNIZE | MATCHES | MAX | MEMBER
    \\  | MERGE | METHOD | MIN | MINUTE | MOD | MODIFIES | MODULE | MONTH | MULTISET
    \\  | NATIONAL | NATURAL | NCHAR | NCLOB | NEW | NO | NONE | NORMALIZE | NOT
    \\  | NTH_VALUE | NTILE | NULL | NULLIF | NUMERIC
    \\  | OCTET_LENGTH | OCCURRENCES_REGEX | OF | OFFSET | OLD | OMIT | ON | ONE
    \\  | ONLY | OPEN | OR | ORDER | OUT | OUTER | OVER | OVERLAPS | OVERLAY
    \\  | PARAMETER | PARTITION | PATTERN | PER | PERCENT | PERCENT_RANK
    \\  | PERCENTILE_CONT | PERCENTILE_DISC | PERIOD | PORTION | POSITION | POSITION_REGEX
    \\  | POWER | PRECEDES | PRECISION | PREPARE | PRIMARY | PROCEDURE | PTF
    \\  | RANGE | RANK | READS | REAL | RECURSIVE | REF | REFERENCES | REFERENCING
    \\  | REGR_AVGX | REGR_AVGY | REGR_COUNT | REGR_INTERCEPT | REGR_R2 | REGR_SLOPE
    \\  | REGR_SXX | REGR_SXY | REGR_SYY | RELEASE | RESULT | RETURN | RETURNS
    \\  | REVOKE | RIGHT | ROLLBACK | ROLLUP | ROW | ROW_NUMBER | ROWS | RUNNING
    \\  | SAVEPOINT | SCOPE | SCROLL | SEARCH | SECOND | SEEK | SELECT | SENSITIVE
    \\  | SESSION_USER | SET | SHOW | SIMILAR | SIN | SINH | SKIP | SMALLINT | SOME | SPECIFIC
    \\  | SPECIFICTYPE | SQL | SQLEXCEPTION | SQLSTATE | SQLWARNING | SQRT | START
    \\  | STATIC | STDDEV_POP | STDDEV_SAMP | SUBMULTISET | SUBSET | SUBSTRING
    \\  | SUBSTRING_REGEX | SUCCEEDS | SUM | SYMMETRIC | SYSTEM | SYSTEM_TIME
    \\  | SYSTEM_USER
    \\  | TABLE | TABLESAMPLE | TAN | TANH | THEN | TIME | TIMESTAMP | TIMEZONE_HOUR
    \\  | TIMEZONE_MINUTE | TO | TRAILING | TRANSLATE | TRANSLATE_REGEX | TRANSLATION | TREAT
    \\  | TRIGGER | TRIM | TRIM_ARRAY | TRUE | TRUNCATE
    \\  | UESCAPE | UNION | UNIQUE | UNKNOWN | UNNEST | UPDATE | UPPER | USER | USING
    \\  | VALUE | VALUES | VALUE_OF | VAR_POP | VAR_SAMP | VARBINARY
    \\  | VARCHAR | VARYING | VERSIONING
    \\  | WHEN | WHENEVER | WHERE | WIDTH_BUCKET | WINDOW | WITH | WITHIN | WITHOUT
    \\  | YEAR
;
