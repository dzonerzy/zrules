//! Types: what type every expression has, and whether the program uses
//! them consistently.
//!
//! The caller matches the selectors and says which nodes play which role
//! (a literal, a variable declaration, a call, ...); this works out types
//! bottom-up and on demand, and reports the mismatches.
//!
//! Inference is local: a variable without an annotation takes the type of
//! its initializer, and anything unannotated beyond that is `unknown`, which
//! is compatible with everything. A program with no annotations at all gets
//! no type errors; each annotation added makes the checks around it real.
//!
//! Types are interned in a table shared by all the files of a project, so a
//! type that crosses an import is the same id on both sides.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree_mod = @import("tree.zig");
const scopes = @import("scopes.zig");
const Tree = tree_mod.Tree;
const NONE = tree_mod.NONE;

pub const TypeId = u32;
/// Nothing is known: compatible with every type, never reported
pub const UNKNOWN: TypeId = 0;

pub const Kind = enum {
    unknown,
    /// A named built-in type: `int`, `str`, `void`, ...
    basic,
    /// A type declared in the program (a struct, a class, an enum), by the
    /// file and node that define it
    nominal,
    /// A constructor applied to types: `list[int]`, `map[str, int]`, and the
    /// two built-in ones: `?[T]` (optional, written `T?`) and `type[T]` (the
    /// type T itself used as a value, as when calling a struct's name)
    generic,
    /// `fn(A, B) -> R`
    function,
};

pub const Type = struct {
    kind: Kind = .unknown,
    name: []const u8 = "",
    file: u32 = NONE,
    node: u32 = NONE,
    /// generic: its arguments. function: its parameters.
    args: []const TypeId = &.{},
    /// function: its result
    ret: TypeId = UNKNOWN,
    /// function: accepts any number of any arguments (`fn(...) -> R`)
    variadic: bool = false,
};

/// How deep types may depend on one another before the rest is put off. The
/// checker recurses, and a long chain (`a = b`, `b = c`, ... over thousands
/// of lines or files) must not run out of stack.
const MAX_DEPTH = 100;

/// Deepest a type written in an option may nest
const MAX_PARSE_DEPTH = 64;

const What = enum(u8) { expr, symbol, type_node };

const Work = struct {
    depth: u32 = 0,
    /// Times the depth limit was hit: a computation during which this moved
    /// is incomplete, and is neither remembered nor allowed to report
    overflows: u32 = 0,
    /// What was put off, to work out from the top (a stack)
    pending: std.ArrayList(Item) = .empty,

    const Item = struct { checker: *Checker, what: What, id: u32 };
};

/// One computation in progress
const Frame = struct {
    outer: u64,
    mark: u32,
    problems: usize,
};

/// Every type of a check, interned: equal types have equal ids.
pub const Table = struct {
    arena: Allocator,
    types: std.ArrayList(Type) = .empty,
    /// Canonical spelling -> id
    index: std.StringHashMapUnmanaged(TypeId) = .empty,
    /// Shared by the checkers of every file: types depend on one another across files
    work: Work = .{},
    /// What a function type written without a result (`fn(int)`) returns
    void_name: []const u8 = "void",

    pub fn init(arena: Allocator) !Table {
        var self = Table{ .arena = arena };
        try self.types.append(arena, .{});
        return self;
    }

    pub fn get(self: *const Table, id: TypeId) Type {
        return self.types.items[id];
    }

    fn intern(self: *Table, t: Type) !TypeId {
        var key: std.ArrayList(u8) = .empty;
        try self.write(&key, t, true);
        const entry = try self.index.getOrPut(self.arena, key.items);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(self.types.items.len);
            // The table outlives the sources its names were read from
            var kept = t;
            kept.name = try self.arena.dupe(u8, t.name);
            try self.types.append(self.arena, kept);
        }
        return entry.value_ptr.*;
    }

    pub fn basic(self: *Table, name: []const u8) !TypeId {
        return self.intern(.{ .kind = .basic, .name = name });
    }

    pub fn nominal(self: *Table, name: []const u8, file: u32, node: u32) !TypeId {
        return self.intern(.{ .kind = .nominal, .name = name, .file = file, .node = node });
    }

    pub fn generic(self: *Table, name: []const u8, args: []const TypeId) !TypeId {
        return self.intern(.{ .kind = .generic, .name = name, .args = try self.arena.dupe(TypeId, args) });
    }

    pub fn function(self: *Table, params: []const TypeId, ret: TypeId, variadic: bool) !TypeId {
        return self.intern(.{ .kind = .function, .args = try self.arena.dupe(TypeId, params), .ret = ret, .variadic = variadic });
    }

    /// Spell a type. `exact` tells two declared types of the same name
    /// apart (the interning key); without it, it is what a user reads.
    fn write(self: *const Table, out: *std.ArrayList(u8), t: Type, exact: bool) Allocator.Error!void {
        const a = self.arena;
        switch (t.kind) {
            .unknown => try out.appendSlice(a, "unknown"),
            .basic => try out.appendSlice(a, t.name),
            .nominal => {
                try out.appendSlice(a, t.name);
                if (exact) {
                    var buf: [32]u8 = undefined;
                    try out.appendSlice(a, std.fmt.bufPrint(&buf, "#{d}:{d}", .{ t.file, t.node }) catch unreachable);
                }
            },
            .generic => {
                if (std.mem.eql(u8, t.name, "?") and t.args.len == 1 and !exact) {
                    try self.write(out, self.get(t.args[0]), exact);
                    return out.append(a, '?');
                }
                try out.appendSlice(a, t.name);
                try out.append(a, '[');
                for (t.args, 0..) |arg, i| {
                    if (i != 0) try out.appendSlice(a, ", ");
                    try self.write(out, self.get(arg), exact);
                }
                try out.append(a, ']');
            },
            .function => {
                try out.appendSlice(a, "fn(");
                for (t.args, 0..) |arg, i| {
                    if (i != 0) try out.appendSlice(a, ", ");
                    try self.write(out, self.get(arg), exact);
                }
                if (t.variadic) try out.appendSlice(a, if (t.args.len != 0) ", ..." else "...");
                try out.appendSlice(a, ") -> ");
                try self.write(out, self.get(t.ret), exact);
            },
        }
    }

    /// The type as a user would write it.
    pub fn format(self: *const Table, id: TypeId) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.write(&out, self.get(id), false);
        return out.items;
    }

    pub const ParseError = error{ BadType, OutOfMemory };

    /// Parse a type written in an option: `int`, `list[int]`, `str?`,
    /// `fn(int, str) -> bool`, `fn(...) -> void`. Names are basic types;
    /// `unknown` and `any` mean "not checked".
    pub fn parse(self: *Table, text: []const u8) ParseError!TypeId {
        var p = Parser{ .table = self, .text = text };
        const id = try p.one();
        p.skip();
        if (p.pos != text.len) return error.BadType;
        return id;
    }

    const Parser = struct {
        table: *Table,
        text: []const u8,
        pos: usize = 0,
        depth: u32 = 0,

        fn skip(self: *Parser) void {
            while (self.pos < self.text.len and self.text[self.pos] == ' ') self.pos += 1;
        }

        fn eat(self: *Parser, s: []const u8) bool {
            self.skip();
            if (!std.mem.startsWith(u8, self.text[self.pos..], s)) return false;
            self.pos += s.len;
            return true;
        }

        fn one(self: *Parser) ParseError!TypeId {
            self.skip();
            if (self.depth >= MAX_PARSE_DEPTH) return error.BadType;
            self.depth += 1;
            defer self.depth -= 1;
            var id: TypeId = undefined;
            const start = self.pos;
            while (self.pos < self.text.len and (std.ascii.isAlphanumeric(self.text[self.pos]) or self.text[self.pos] == '_')) self.pos += 1;
            const name = self.text[start..self.pos];
            if (name.len == 0) return error.BadType;
            if (std.mem.eql(u8, name, "fn") and self.eat("(")) {
                var params: std.ArrayList(TypeId) = .empty;
                var variadic = false;
                if (!self.eat(")")) {
                    while (true) {
                        if (self.eat("...")) variadic = true else try params.append(self.table.arena, try self.one());
                        if (self.eat(")")) break;
                        if (!self.eat(",")) return error.BadType;
                    }
                }
                const ret = if (self.eat("->")) try self.one() else try self.table.basic(self.table.void_name);
                id = try self.table.function(params.items, ret, variadic);
            } else if (self.eat("[")) {
                var args: std.ArrayList(TypeId) = .empty;
                while (true) {
                    try args.append(self.table.arena, try self.one());
                    if (self.eat("]")) break;
                    if (!self.eat(",")) return error.BadType;
                }
                id = try self.table.generic(name, args.items);
            } else if (std.mem.eql(u8, name, "unknown") or std.mem.eql(u8, name, "any")) {
                id = UNKNOWN;
            } else id = try self.table.basic(name);
            while (self.eat("?")) id = try self.table.generic("?", &.{id});
            return id;
        }
    };
};

/// Field ids (index into the grammar's labels plus one; 0 = no such label)
/// of the children each kind of node is read through
pub const Labels = struct {
    name: u8 = 0,
    type: u8 = 0,
    value: u8 = 0,
    params: u8 = 0,
    returns: u8 = 0,
    left: u8 = 0,
    op: u8 = 0,
    right: u8 = 0,
    operand: u8 = 0,
    callee: u8 = 0,
    args: u8 = 0,
    target: u8 = 0,
    index: u8 = 0,
    base: u8 = 0,
    items: u8 = 0,
};

/// One row of the operator table. `left`, `right` and `result` are types as
/// text; `T` stands for "the same type on both sides" and `any` for any
/// type. A unary operator has only `right`.
pub const Operator = struct {
    op: []const u8,
    left: []const u8 = "",
    right: []const u8,
    result: []const u8,
};

pub const Literal = struct {
    nodes: []const u32,
    type: []const u8,
};

/// A literal that holds items (`[1, 2, 3]`): `name[T]`, T being the type
/// of its children labelled `items`
pub const Container = struct {
    nodes: []const u32,
    name: []const u8,
};

pub const ProblemKind = enum {
    mismatch,
    operator,
    arity,
    argument,
    not_callable,
    no_field,
    bad_return,
    condition,
    unknown_type,
    not_indexable,
};

pub const Problem = struct {
    kind: ProblemKind,
    node: u32,
    message: []const u8,
    /// The computation that reported it (0 = none: a check from the top)
    frame: u64 = 0,
};

/// What the language calls the types the checker itself needs: a condition
/// is `bool`, a list's index `int`, indexing a `str` gives a `str`, a
/// `return;` returns `void`, and `nil` fits any optional
pub const Names = struct {
    bool: []const u8 = "bool",
    void: []const u8 = "void",
    nil: []const u8 = "nil",
    int: []const u8 = "int",
    str: []const u8 = "str",
};

/// What the caller matched for one file (node lists in source order)
pub const Inputs = struct {
    labels: Labels,
    names: Names = .{},
    literals: []const Literal = &.{},
    containers: []const Container = &.{},
    /// Nodes whose text names a type; nodes applying a type to arguments
    /// (children `base` and `args`); nodes making a type optional
    type_names: []const u32 = &.{},
    type_args: []const u32 = &.{},
    optionals: []const u32 = &.{},
    /// Declarations of one name: child `name`, optional `type`, optional `value`
    variables: []const u32 = &.{},
    /// Child `name`, children `params`, optional `returns`
    functions: []const u32 = &.{},
    /// Child `name`; the variables and functions declared in its scope are its members
    structs: []const u32 = &.{},
    binaries: []const u32 = &.{},
    unaries: []const u32 = &.{},
    calls: []const u32 = &.{},
    indexes: []const u32 = &.{},
    members: []const scopes.Member = &.{},
    /// Child `target` (or `name`), child `value`
    assigns: []const u32 = &.{},
    /// Optional child `value`
    returns: []const u32 = &.{},
    /// Expressions that must be `bool`
    conditions: []const u32 = &.{},
    operators: []const Operator = &.{},
    /// Names of the built-in types (`int`, `str`, ...)
    basic: []const []const u8 = &.{},
    /// Implicit conversions, as (from, to) type texts
    coerce: []const [2][]const u8 = &.{},
    /// Types of names defined by the rules, as (name, type text)
    builtins: []const [2][]const u8 = &.{},
    /// The nodes the name resolution treats as uses (sorted): an unknown
    /// type among them has already been reported as an undefined name
    uses: []const u32 = &.{},
};

const Role = enum(u8) { none, literal, container, binary, unary, call, index, member, type_name, type_args, optional };

const UNSET: TypeId = std.math.maxInt(TypeId);
const BUSY: TypeId = UNSET - 1;

/// The type checker of one file.
pub const Checker = struct {
    arena: Allocator,
    table: *Table,
    tree: *const Tree,
    names: *const scopes.Result,
    in: Inputs,
    file: u32,
    /// The checkers of every file of the project, by file index
    others: []const *Checker = &.{},
    problems: std.ArrayList(Problem) = .empty,

    role: []Role = &.{},
    literal_type: []TypeId = &.{},
    /// Container node -> its constructor's name
    container_name: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// Memo per node: its type as an expression (UNSET / BUSY while unknown)
    expr: []TypeId = &.{},
    /// Memo per symbol of `names`
    symbol: []TypeId = &.{},
    /// Name node -> the declaration it belongs to
    variable_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    function_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    struct_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    is_function: []bool = &.{},
    member_of: std.AutoHashMapUnmanaged(u32, scopes.Member) = .empty,
    coerce: std.ArrayList([2]TypeId) = .empty,
    builtin_types: std.StringHashMapUnmanaged(TypeId) = .empty,
    /// Type expressions already evaluated (each reports its problems once)
    type_nodes: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    /// Scope node -> the types of the fields declared in it
    field_types: std.AutoHashMapUnmanaged(u32, []const TypeId) = .empty,
    /// Scope node -> the symbols of the variables declared directly in it
    fields_of: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    fields_grouped: bool = false,
    /// The computation in progress in this file (0 = none)
    frame: u64 = 0,
    bool_type: TypeId = UNKNOWN,
    void_type: TypeId = UNKNOWN,
    nil_type: TypeId = UNKNOWN,
    int_type: TypeId = UNKNOWN,
    str_type: TypeId = UNKNOWN,

    const Error = Allocator.Error;

    pub fn prepare(self: *Checker) Table.ParseError!void {
        const n = self.tree.nodes.len;
        self.role = try self.arena.alloc(Role, n);
        @memset(self.role, .none);
        self.literal_type = try self.arena.alloc(TypeId, n);
        self.expr = try self.arena.alloc(TypeId, n);
        @memset(self.expr, UNSET);
        self.is_function = try self.arena.alloc(bool, n);
        @memset(self.is_function, false);

        for (self.in.literals) |lit| {
            const id = try self.table.parse(lit.type);
            for (lit.nodes) |node| {
                self.role[node] = .literal;
                self.literal_type[node] = id;
            }
        }
        for (self.in.containers) |container| {
            for (container.nodes) |node| {
                self.role[node] = .container;
                try self.container_name.put(self.arena, node, container.name);
            }
        }
        inline for (.{
            .{ "type_names", Role.type_name }, .{ "type_args", Role.type_args }, .{ "optionals", Role.optional },
            .{ "binaries", Role.binary },      .{ "unaries", Role.unary },       .{ "calls", Role.call },
            .{ "indexes", Role.index },
        }) |pair| {
            for (@field(self.in, pair[0])) |node| self.role[node] = pair[1];
        }
        for (self.in.members) |m| {
            self.role[m.node] = .member;
            try self.member_of.put(self.arena, m.node, m);
        }
        for (self.in.variables) |node| {
            const name = self.child(node, self.in.labels.name);
            try self.variable_of.put(self.arena, if (name != NONE) name else node, node);
        }
        for (self.in.functions) |node| {
            self.is_function[node] = true;
            const name = self.child(node, self.in.labels.name);
            if (name != NONE) try self.function_of.put(self.arena, name, node);
        }
        for (self.in.structs) |node| {
            const name = self.child(node, self.in.labels.name);
            if (name != NONE) try self.struct_of.put(self.arena, name, node);
        }
        self.table.void_name = self.in.names.void;
        for (self.in.basic) |name| _ = try self.table.basic(name);
        for (self.in.coerce) |pair| try self.coerce.append(self.arena, .{ try self.table.parse(pair[0]), try self.table.parse(pair[1]) });
        for (self.in.builtins) |pair| try self.builtin_types.put(self.arena, pair[0], try self.table.parse(pair[1]));

        self.symbol = try self.arena.alloc(TypeId, self.names.symbols.items.len);
        @memset(self.symbol, UNSET);
        self.bool_type = try self.table.basic(self.in.names.bool);
        self.void_type = try self.table.basic(self.in.names.void);
        self.nil_type = try self.table.basic(self.in.names.nil);
        self.int_type = try self.table.basic(self.in.names.int);
        self.str_type = try self.table.basic(self.in.names.str);
    }

    // ── Tree helpers ──

    /// The first child of `node` labelled `field`, or NONE.
    fn child(self: *const Checker, node: u32, field: u8) u32 {
        if (field == 0) return NONE;
        const t = self.tree;
        const stop = t.end(node);
        var c = node + 1;
        while (c < stop) : (c = t.end(c)) {
            if (t.nodes[c].fieldId() == field) return c;
        }
        return NONE;
    }

    fn children(self: *const Checker, node: u32, field: u8) Error![]const u32 {
        var out: std.ArrayList(u32) = .empty;
        if (field == 0) return out.items;
        const t = self.tree;
        const stop = t.end(node);
        var c = node + 1;
        while (c < stop) : (c = t.end(c)) {
            if (t.nodes[c].fieldId() == field) try out.append(self.arena, c);
        }
        return out.items;
    }

    fn report(self: *Checker, kind: ProblemKind, node: u32, comptime fmt: []const u8, args: anytype) Error!void {
        try self.problems.append(self.arena, .{ .kind = kind, .node = node, .message = try std.fmt.allocPrint(self.arena, fmt, args), .frame = self.frame });
    }

    // ── Depth ──

    /// Start a computation, or put it off (null) if it is too deep.
    fn begin(self: *Checker, what: What, id: u32) Error!?Frame {
        const work = &self.table.work;
        if (work.depth >= MAX_DEPTH) {
            work.overflows += 1;
            try work.pending.append(self.table.arena, .{ .checker = self, .what = what, .id = id });
            return null;
        }
        work.depth += 1;
        const frame = Frame{ .outer = self.frame, .mark = work.overflows, .problems = self.problems.items.len };
        self.frame = (@as(u64, @intFromEnum(what) + 1) << 32) | id;
        return frame;
    }

    /// End a computation. False if something it needed was put off: its
    /// result must not be remembered, and what it reported is taken back
    /// (it runs again later, and what it saw may have been incomplete).
    fn finish(self: *Checker, frame: Frame) bool {
        const work = &self.table.work;
        work.depth -= 1;
        const whole = work.overflows == frame.mark;
        if (!whole) {
            var keep = frame.problems;
            for (self.problems.items[frame.problems..]) |p| {
                if (p.frame == self.frame) continue;
                self.problems.items[keep] = p;
                keep += 1;
            }
            self.problems.shrinkRetainingCapacity(keep);
        }
        self.frame = frame.outer;
        return whole;
    }

    fn run(self: *Checker, what: What, id: u32) Error!TypeId {
        return switch (what) {
            .expr => self.typeOf(id),
            .symbol => self.symbolType(id),
            .type_node => self.typeNode(id),
        };
    }

    /// A type asked for from the top (not from inside another computation):
    /// whatever was put off on the way is worked out, then it is asked again.
    pub fn settled(self: *Checker, what: What, id: u32) Error!TypeId {
        const work = &self.table.work;
        while (true) {
            const mark = work.overflows;
            const result = try self.run(what, id);
            if (work.overflows == mark) return result;
            while (work.pending.items.len > 0) {
                const item = work.pending.items[work.pending.items.len - 1];
                const before = work.overflows;
                _ = try item.checker.run(item.what, item.id);
                // Unless it put off something deeper (now above it), it is done
                if (work.overflows == before) _ = work.pending.pop();
            }
        }
    }

    fn show(self: *const Checker, id: TypeId) Error![]const u8 {
        return self.table.format(id);
    }

    // ── Types written in the source ──

    /// The type a type expression stands for.
    pub fn typeNode(self: *Checker, node: u32) Error!TypeId {
        if (self.type_nodes.get(node)) |id| return id;
        const frame = try self.begin(.type_node, node) orelse return UNKNOWN;
        const id = try self.computeTypeNode(node);
        if (self.finish(frame)) try self.type_nodes.put(self.arena, node, id);
        return id;
    }

    fn computeTypeNode(self: *Checker, node: u32) Error!TypeId {
        const t = self.tree;
        switch (self.role[node]) {
            .type_name => {
                const text = t.text(node);
                // A declared type (here or imported) wins over a basic one of the same name
                if (self.names.symbolOf(node)) |sym| {
                    const declared = try self.symbolType(sym);
                    const d = self.table.get(declared);
                    if (d.kind == .generic and std.mem.eql(u8, d.name, "type") and d.args.len == 1) return d.args[0];
                }
                if (std.mem.eql(u8, text, "unknown") or std.mem.eql(u8, text, "any")) return UNKNOWN;
                if (self.isBasic(text)) return self.table.basic(text);
                // A use that resolved to nothing is already an undefined name
                const already_reported = self.names.symbolOf(node) == null and std.sort.binarySearch(u32, self.in.uses, node, struct {
                    fn order(a: u32, b: u32) std.math.Order {
                        return std.math.order(a, b);
                    }
                }.order) != null;
                if (!already_reported) try self.report(.unknown_type, node, "unknown type '{s}'", .{text});
                return UNKNOWN;
            },
            .type_args => {
                const base = self.child(node, self.in.labels.base);
                var args: std.ArrayList(TypeId) = .empty;
                for (try self.children(node, self.in.labels.args)) |arg| try args.append(self.arena, try self.typeNode(arg));
                return self.table.generic(if (base != NONE) t.text(base) else "", args.items);
            },
            .optional => {
                const inner = node + 1;
                if (inner >= t.end(node)) return UNKNOWN;
                return self.table.generic("?", &.{try self.typeNode(inner)});
            },
            else => {
                // A wrapper around one type expression
                const inner = node + 1;
                if (inner < t.end(node) and t.end(inner) == t.end(node)) return self.typeNode(inner);
                return UNKNOWN;
            },
        }
    }

    fn isBasic(self: *const Checker, name: []const u8) bool {
        return self.table.index.contains(name) and self.table.get(self.table.index.get(name).?).kind == .basic;
    }

    // ── Symbols ──

    /// The type of what a symbol names.
    pub fn symbolType(self: *Checker, index: u32) Error!TypeId {
        if (self.symbol[index] == BUSY) return UNKNOWN; // defined in terms of itself
        if (self.symbol[index] != UNSET) return self.symbol[index];
        const frame = try self.begin(.symbol, index) orelse return UNKNOWN;
        self.symbol[index] = BUSY;
        const id = try self.computeSymbol(index);
        self.symbol[index] = if (self.finish(frame)) id else UNSET;
        return id;
    }

    fn computeSymbol(self: *Checker, index: u32) Error!TypeId {
        const sym = self.names.symbols.items[index];
        if (sym.origin_file != NONE) {
            // Imported: it has the type its own file gives it
            if (sym.origin_file >= self.others.len) return UNKNOWN;
            return self.others[sym.origin_file].definitionType(sym.origin_node);
        }
        if (sym.node == NONE) return self.builtin_types.get(sym.name) orelse UNKNOWN;
        return self.declarationType(sym.node);
    }

    /// The type of the name defined at `node` of this file.
    pub fn definitionType(self: *Checker, node: u32) Error!TypeId {
        if (self.names.symbolOf(node)) |sym| return self.symbolType(sym);
        return self.declarationType(node);
    }

    fn declarationType(self: *Checker, name_node: u32) Error!TypeId {
        const labels = self.in.labels;
        if (self.variable_of.get(name_node)) |decl| {
            const annotation = self.child(decl, labels.type);
            if (annotation != NONE) return self.typeNode(annotation);
            const value = self.child(decl, labels.value);
            if (value != NONE) return self.typeOf(value);
            return UNKNOWN;
        }
        if (self.function_of.get(name_node)) |decl| return self.functionType(decl);
        if (self.struct_of.get(name_node)) |_| {
            const declared = try self.table.nominal(self.tree.text(name_node), self.file, name_node);
            return self.table.generic("type", &.{declared});
        }
        return UNKNOWN;
    }

    fn functionType(self: *Checker, decl: u32) Error!TypeId {
        const labels = self.in.labels;
        var params: std.ArrayList(TypeId) = .empty;
        for (try self.children(decl, labels.params)) |param| try params.append(self.arena, try self.parameterType(param));
        const returns = self.child(decl, labels.returns);
        return self.table.function(params.items, if (returns != NONE) try self.typeNode(returns) else UNKNOWN, false);
    }

    /// A parameter is a variable declaration (with its own annotation) or a bare name.
    fn parameterType(self: *Checker, param: u32) Error!TypeId {
        const annotation = self.child(param, self.in.labels.type);
        return if (annotation != NONE) self.typeNode(annotation) else UNKNOWN;
    }

    /// The member `name` of a declared type, as (checker, symbol index).
    fn memberOf(self: *Checker, owner: Type, name: []const u8) ?struct { *Checker, u32 } {
        if (owner.kind != .nominal or owner.file >= self.others.len) return null;
        const home = self.others[owner.file];
        const sym = home.names.symbolOf(owner.node) orelse return null;
        const scope = home.names.symbols.items[sym].owns;
        if (scope == NONE) return null;
        return .{ home, home.names.lookup(scope, name) orelse return null };
    }

    // ── Expressions ──

    /// The type of `node` as an expression.
    pub fn typeOf(self: *Checker, node: u32) Error!TypeId {
        if (self.expr[node] == BUSY) return UNKNOWN;
        if (self.expr[node] != UNSET) return self.expr[node];
        const frame = try self.begin(.expr, node) orelse return UNKNOWN;
        self.expr[node] = BUSY;
        const id = try self.compute(node);
        self.expr[node] = if (self.finish(frame)) id else UNSET;
        return id;
    }

    fn compute(self: *Checker, node: u32) Error!TypeId {
        const t = self.tree;
        const labels = self.in.labels;
        switch (self.role[node]) {
            .literal => return self.literal_type[node],
            .container => {
                // name[T]: T is what the first item is; the others must fit it
                var item_type: TypeId = UNKNOWN;
                for (try self.children(node, labels.items)) |item| {
                    const it = try self.typeOf(item);
                    if (item_type == UNKNOWN) {
                        item_type = it;
                    } else if (self.assignable(item_type, it)) {
                        item_type = it; // the wider of the two (int, then float)
                    } else if (!self.assignable(it, item_type)) {
                        try self.report(.mismatch, item, "expected an item of type '{s}', got '{s}'", .{ try self.show(item_type), try self.show(it) });
                    }
                }
                return self.table.generic(self.container_name.get(node).?, &.{item_type});
            },
            .binary => {
                const left = self.child(node, labels.left);
                const right = self.child(node, labels.right);
                const op = self.child(node, labels.op);
                if (left == NONE or right == NONE) return UNKNOWN;
                const l = try self.typeOf(left);
                const r = try self.typeOf(right);
                const op_text = if (op != NONE) t.text(op) else "";
                return try self.operator(node, op_text, l, r, false);
            },
            .unary => {
                const operand = self.child(node, labels.operand);
                if (operand == NONE) return UNKNOWN;
                const op = self.child(node, labels.op);
                // Without an `op` child, the operator is what precedes the operand
                const op_text = if (op != NONE) t.text(op) else std.mem.trim(u8, t.input[t.nodes[node].text_start..t.nodes[operand].text_start], " \t\r\n");
                return try self.operator(node, op_text, UNKNOWN, try self.typeOf(operand), true);
            },
            .call => return self.call(node),
            .index => {
                const target = self.child(node, labels.target);
                const index = self.child(node, labels.index);
                if (target == NONE) return UNKNOWN;
                const tt = try self.typeOf(target);
                const it = if (index != NONE) try self.typeOf(index) else UNKNOWN;
                const ty = self.table.get(tt);
                if (ty.kind == .unknown) return UNKNOWN;
                var key: TypeId = self.int_type;
                var result: TypeId = UNKNOWN;
                if (tt == self.str_type) {
                    result = self.str_type;
                } else if (ty.kind == .generic and ty.args.len == 1 and !std.mem.eql(u8, ty.name, "?") and !std.mem.eql(u8, ty.name, "type")) {
                    result = ty.args[0];
                } else if (ty.kind == .generic and ty.args.len == 2) {
                    key = ty.args[0];
                    result = ty.args[1];
                } else {
                    try self.report(.not_indexable, target, "'{s}' cannot be indexed", .{try self.show(tt)});
                    return UNKNOWN;
                }
                if (index != NONE and !self.assignable(it, key)) {
                    try self.report(.mismatch, index, "expected an index of type '{s}', got '{s}'", .{ try self.show(key), try self.show(it) });
                }
                return result;
            },
            .member => {
                const m = self.member_of.get(node).?;
                // Already resolved by name (an enum's member, a module's)
                if (self.names.symbolOf(node)) |sym| return self.symbolType(sym);
                const owner_id = try self.typeOf(m.target);
                var owner = self.table.get(owner_id);
                if (owner.kind == .generic and std.mem.eql(u8, owner.name, "?") and owner.args.len == 1) owner = self.table.get(owner.args[0]);
                if (owner.kind == .unknown) return UNKNOWN;
                if (self.memberOf(owner, t.text(m.name))) |found| return found[0].symbolType(found[1]);
                try self.report(.no_field, m.name, "'{s}' has no field '{s}'", .{ try self.show(owner_id), t.text(m.name) });
                return UNKNOWN;
            },
            .type_name, .type_args, .optional => return UNKNOWN,
            .none => {},
        }
        // A name: the type of what it refers to
        if (self.names.symbolOf(node)) |sym| return self.symbolType(sym);
        // A wrapper around one expression (parentheses, a pass-through rule)
        const inner = node + 1;
        if (inner < t.end(node) and t.end(inner) == t.end(node)) return self.typeOf(inner);
        return UNKNOWN;
    }

    /// Does a row's type text accept `actual`? `bound` is what `T` stands for.
    fn rowAccepts(self: *Checker, text: []const u8, actual: TypeId, bound: *TypeId) Error!bool {
        if (std.mem.eql(u8, text, "any")) return true;
        if (actual == UNKNOWN) return true;
        if (std.mem.eql(u8, text, "T")) {
            if (bound.* == UNKNOWN) {
                bound.* = actual;
                return true;
            }
            if (self.assignable(actual, bound.*)) return true;
            if (self.assignable(bound.*, actual)) {
                bound.* = actual;
                return true;
            }
            return false;
        }
        const wanted = self.table.parse(text) catch return false;
        return self.assignable(actual, wanted);
    }

    fn operator(self: *Checker, node: u32, op: []const u8, l: TypeId, r: TypeId, unary: bool) Error!TypeId {
        var any_row = false;
        for (self.in.operators) |row| {
            if (!std.mem.eql(u8, row.op, op) or (row.left.len == 0) != unary) continue;
            any_row = true;
            var bound: TypeId = UNKNOWN;
            if (!unary and !try self.rowAccepts(row.left, l, &bound)) continue;
            if (!try self.rowAccepts(row.right, r, &bound)) continue;
            // With an operand unknown, the row may not be the right one
            if ((!unary and l == UNKNOWN) or r == UNKNOWN) return self.commonResult(op, unary);
            if (std.mem.eql(u8, row.result, "T")) return bound;
            return self.table.parse(row.result) catch UNKNOWN;
        }
        if (!any_row) return UNKNOWN; // an operator the table says nothing about
        if (unary) {
            try self.report(.operator, node, "operator '{s}' cannot be applied to '{s}'", .{ op, try self.show(r) });
        } else {
            try self.report(.operator, node, "operator '{s}' cannot be applied to '{s}' and '{s}'", .{ op, try self.show(l), try self.show(r) });
        }
        return self.commonResult(op, unary);
    }

    /// What every row of an operator results in, if they agree (`==` is
    /// always bool, whatever the operands).
    fn commonResult(self: *Checker, op: []const u8, unary: bool) TypeId {
        var result: ?TypeId = null;
        for (self.in.operators) |row| {
            if (!std.mem.eql(u8, row.op, op) or (row.left.len == 0) != unary) continue;
            if (std.mem.eql(u8, row.result, "T")) return UNKNOWN;
            const id = self.table.parse(row.result) catch return UNKNOWN;
            if (result != null and result.? != id) return UNKNOWN;
            result = id;
        }
        return result orelse UNKNOWN;
    }

    fn call(self: *Checker, node: u32) Error!TypeId {
        const t = self.tree;
        const labels = self.in.labels;
        var callee = self.child(node, labels.callee);
        if (callee == NONE) callee = self.child(node, labels.name);
        if (callee == NONE) callee = self.child(node, labels.target);
        const args = try self.children(node, labels.args);
        // Type the arguments whatever happens, so their own errors show
        const arg_types = try self.arena.alloc(TypeId, args.len);
        for (args, arg_types) |arg, *slot| slot.* = try self.typeOf(arg);
        if (callee == NONE) return UNKNOWN;
        const callee_id = try self.typeOf(callee);
        const ct = self.table.get(callee_id);
        const name = t.text(callee);
        switch (ct.kind) {
            .unknown => return UNKNOWN,
            .function => {
                if (ct.variadic and args.len >= ct.args.len) {
                    try self.checkArguments(name, args[0..ct.args.len], arg_types[0..ct.args.len], ct.args);
                    return ct.ret;
                }
                if (args.len != ct.args.len) {
                    try self.report(.arity, node, "{s}() takes {d} argument{s}, got {d}", .{ name, ct.args.len, if (ct.args.len == 1) "" else "s", args.len });
                    return ct.ret;
                }
                try self.checkArguments(name, args, arg_types, ct.args);
                return ct.ret;
            },
            .generic => if (std.mem.eql(u8, ct.name, "type") and ct.args.len == 1) {
                // Calling a declared type constructs it: one argument per field
                const made = self.table.get(ct.args[0]);
                if (made.kind == .nominal and made.file < self.others.len) {
                    const home = self.others[made.file];
                    const fields = try home.fieldTypes(made.node);
                    if (fields.len != args.len) {
                        try self.report(.arity, node, "{s}() takes {d} argument{s}, got {d}", .{ name, fields.len, if (fields.len == 1) "" else "s", args.len });
                    } else try self.checkArguments(name, args, arg_types, fields);
                }
                return ct.args[0];
            },
            else => {},
        }
        try self.report(.not_callable, callee, "'{s}' is not callable: it is '{s}'", .{ name, try self.show(callee_id) });
        return UNKNOWN;
    }

    fn checkArguments(self: *Checker, name: []const u8, args: []const u32, got: []const TypeId, wanted: []const TypeId) Error!void {
        for (args, got, wanted, 1..) |arg, g, w, position| {
            if (self.assignable(g, w)) continue;
            try self.report(.argument, arg, "argument {d} of {s}(): expected '{s}', got '{s}'", .{ position, name, try self.show(w), try self.show(g) });
        }
    }

    /// The types of a declared type's fields, in declaration order: the
    /// variables declared directly in its scope.
    fn fieldTypes(self: *Checker, name_node: u32) Error![]const TypeId {
        var out: std.ArrayList(TypeId) = .empty;
        const sym = self.names.symbolOf(name_node) orelse return out.items;
        const scope = self.names.symbols.items[sym].owns;
        if (scope == NONE) return out.items;
        if (self.field_types.get(scope)) |known_fields| return known_fields;
        // One pass over the symbols groups every scope's variables
        if (!self.fields_grouped) {
            self.fields_grouped = true;
            for (self.names.symbols.items, 0..) |s, i| {
                if (s.scope == NONE or s.node == NONE or !self.variable_of.contains(s.node)) continue;
                const entry = try self.fields_of.getOrPutValue(self.arena, s.scope, .empty);
                try entry.value_ptr.append(self.arena, @intCast(i));
            }
        }
        const mark = self.table.work.overflows;
        if (self.fields_of.get(scope)) |fields| {
            for (fields.items) |i| try out.append(self.arena, try self.symbolType(i));
        }
        if (self.table.work.overflows == mark) try self.field_types.put(self.arena, scope, out.items);
        return out.items;
    }

    // ── Compatibility ──

    /// Can a value of type `from` be used where `to` is expected?
    pub fn assignable(self: *const Checker, from: TypeId, to: TypeId) bool {
        if (from == to or from == UNKNOWN or to == UNKNOWN) return true;
        const f = self.table.get(from);
        const t = self.table.get(to);
        // T? takes nil, a T, or another optional whose inside fits
        if (t.kind == .generic and std.mem.eql(u8, t.name, "?") and t.args.len == 1) {
            if (from == self.nil_type) return true;
            if (f.kind == .generic and std.mem.eql(u8, f.name, "?") and f.args.len == 1) return self.assignable(f.args[0], t.args[0]);
            return self.assignable(from, t.args[0]);
        }
        for (self.coerce.items) |pair| {
            if (pair[0] == from and (pair[1] == to or self.assignable(pair[1], to))) return true;
        }
        if (f.kind != t.kind) return false;
        switch (f.kind) {
            .generic => {
                // list[unknown] fits list[int]; otherwise arguments must be the same
                if (!std.mem.eql(u8, f.name, t.name) or f.args.len != t.args.len) return false;
                for (f.args, t.args) |a, b| {
                    if (a != b and a != UNKNOWN and b != UNKNOWN) return false;
                }
                return true;
            },
            .function => {
                if (f.args.len != t.args.len or f.variadic != t.variadic) return false;
                for (f.args, t.args) |a, b| {
                    if (a != b and a != UNKNOWN and b != UNKNOWN) return false;
                }
                return self.assignable(f.ret, t.ret);
            },
            else => return false,
        }
    }

    // ── The checks ──

    pub fn check(self: *Checker) Error!void {
        const t = self.tree;
        const labels = self.in.labels;

        for (self.in.variables) |decl| {
            const annotation = self.child(decl, labels.type);
            const value = self.child(decl, labels.value);
            if (annotation == NONE) {
                if (value != NONE) _ = try self.settled(.expr, value);
                continue;
            }
            const declared = try self.settled(.type_node, annotation);
            if (value == NONE) continue;
            const got = try self.settled(.expr, value);
            if (!self.assignable(got, declared)) {
                try self.report(.mismatch, value, "expected '{s}', got '{s}'", .{ try self.show(declared), try self.show(got) });
            }
        }

        for (self.in.assigns) |node| {
            var target = self.child(node, labels.target);
            if (target == NONE) target = self.child(node, labels.name);
            const value = self.child(node, labels.value);
            if (target == NONE or value == NONE) continue;
            const wanted = try self.settled(.expr, target);
            const got = try self.settled(.expr, value);
            if (!self.assignable(got, wanted)) {
                try self.report(.mismatch, value, "expected '{s}', got '{s}'", .{ try self.show(wanted), try self.show(got) });
            }
        }

        for (self.in.returns) |node| {
            const value = self.child(node, labels.value);
            const got = if (value != NONE) try self.settled(.expr, value) else self.void_type;
            // The function it returns from
            var p = t.parents[node];
            while (p != NONE and !self.is_function[p]) p = t.parents[p];
            if (p == NONE) continue;
            const returns = self.child(p, labels.returns);
            if (returns == NONE) continue;
            const wanted = try self.settled(.type_node, returns);
            if (self.assignable(got, wanted)) continue;
            if (value == NONE) {
                try self.report(.bad_return, node, "missing return value: expected '{s}'", .{try self.show(wanted)});
            } else {
                try self.report(.bad_return, value, "expected to return '{s}', got '{s}'", .{ try self.show(wanted), try self.show(got) });
            }
        }

        for (self.in.conditions) |node| {
            const got = try self.settled(.expr, node);
            if (!self.assignable(got, self.bool_type)) {
                try self.report(.condition, node, "expected a condition of type '{s}', got '{s}'", .{ try self.show(self.bool_type), try self.show(got) });
            }
        }

        // Everything else that can be wrong in itself
        inline for (.{ "binaries", "unaries", "calls", "indexes" }) |list| {
            for (@field(self.in, list)) |node| _ = try self.settled(.expr, node);
        }
        for (self.in.members) |m| _ = try self.settled(.expr, m.node);
        // Types written anywhere else (each is evaluated, and reported, once)
        inline for (.{ "type_names", "type_args", "optionals" }) |list| {
            for (@field(self.in, list)) |node| _ = try self.settled(.type_node, node);
        }
    }

    /// Work out every type that hasn't been needed yet, so that later
    /// questions (`known`) are answered from memory: once the check is over,
    /// the other files may be gone.
    pub fn complete(self: *Checker) Error!void {
        for (0..self.symbol.len) |i| _ = try self.settled(.symbol, @intCast(i));
        // Backwards: children before their parents, so nothing goes deep
        var node = self.expr.len;
        while (node > 0) {
            node -= 1;
            if (self.role[node] == .type_name or self.role[node] == .type_args or self.role[node] == .optional) continue;
            _ = try self.settled(.expr, @intCast(node));
        }
    }

    /// After `complete`: the type of a node (as a type expression if it is
    /// one, else as an expression), without computing anything.
    pub fn known(self: *const Checker, node: u32) TypeId {
        if (node >= self.expr.len) return UNKNOWN;
        if (self.type_nodes.get(node)) |id| return id;
        const id = self.expr[node];
        return if (id == UNSET or id == BUSY) UNKNOWN else id;
    }

    /// After `complete`: the type of a symbol.
    pub fn knownSymbol(self: *const Checker, index: usize) TypeId {
        if (index >= self.symbol.len) return UNKNOWN;
        const id = self.symbol[index];
        return if (id == UNSET or id == BUSY) UNKNOWN else id;
    }
};
