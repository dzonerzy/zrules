//! zrules: static rules over zgram parse trees.
//!
//! A `Rules` object holds rules compiled against a grammar; `check(tree)`
//! walks the tree natively (through zgram's `zgram.tree.v1` capsule) and
//! returns `zgram.Diagnostic`s.

const std = @import("std");
const pyoz = @import("PyOZ");
const py = pyoz.py;
const PyObject = pyoz.PyObject;

const tree_mod = @import("tree.zig");
const selector = @import("selector.zig");
const scopes_mod = @import("scopes.zig");
const types_mod = @import("types.zig");
const flow_mod = @import("flow.zig");
const native_abi = @import("native_abi.zig");
const Tree = tree_mod.Tree;
const Selector = selector.Selector;
const NONE = tree_mod.NONE;

const allocator = std.heap.c_allocator;

// ============================================================================
// Python helpers
// ============================================================================

/// Raise `exc` with a formatted message.
fn raise(exc: *PyObject, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch blk: {
        buf[buf.len - 1] = 0;
        break :blk buf[0 .. buf.len - 1 :0];
    };
    py.PyErr_SetString(exc, msg.ptr);
}

/// UTF-8 of a str object (borrowed from the object), or null with TypeError set.
fn utf8(obj: *PyObject, what: []const u8) ?[]const u8 {
    if (!py.PyUnicode_Check(obj)) {
        raise(py.PyExc_TypeError(), "{s} must be a str", .{what});
        return null;
    }
    var len: py.Py_ssize_t = 0;
    const ptr = py.c.PyUnicode_AsUTF8AndSize(obj, &len) orelse return null;
    return ptr[0..@intCast(len)];
}

// ============================================================================
// Rule: what inside(), unique(), ... return
// ============================================================================

const Kind = enum(u8) { inside, unique, forbid, require, count, scopes, custom, types, flow };

/// A rule as written, before it is compiled against a grammar by Rules().
const Rule = struct {
    _kind: u8 = 0,
    /// dict of the arguments it was created with
    _args: ?*PyObject = null,

    pub fn __del__(self: *Rule) void {
        if (self._args) |a| py.Py_DecRef(a);
        self._args = null;
    }

    pub fn get_kind(self: *const Rule) []const u8 {
        return @tagName(@as(Kind, @enumFromInt(self._kind)));
    }

    pub fn __repr__(self: *const Rule, buf: []u8) []const u8 {
        var sel: []const u8 = "?";
        if (self._args) |a| {
            if (py.c.PyDict_GetItemString(a, "selector")) |s| {
                var len: py.Py_ssize_t = 0;
                if (py.c.PyUnicode_AsUTF8AndSize(s, &len)) |ptr| sel = ptr[0..@intCast(len)] else py.c.PyErr_Clear();
            }
        }
        return std.fmt.bufPrint(buf, "{s}({s})", .{ self.get_kind(), sel[0..@min(sel.len, 120)] }) catch buf[0..0];
    }

    pub const __doc__: [*:0]const u8 = "A rule, as returned by inside(), unique(), forbid(), require() and count(). Pass rules to Rules(parser, [...]).";
};

/// Build a Rule from (name, value) pairs; null values are left out.
fn makeRule(kind: Kind, pairs: anytype) ?Rule {
    const dict = py.c.PyDict_New() orelse return null;
    inline for (pairs) |pair| {
        const value: ?*PyObject = pair[1];
        if (value) |v| {
            if (v != py.Py_None() and py.c.PyDict_SetItemString(dict, pair[0], v) != 0) {
                py.Py_DecRef(dict);
                return null;
            }
        }
    }
    return .{ ._kind = @intFromEnum(kind), ._args = dict };
}

const Common = struct {
    selector: *PyObject,
    message: ?*PyObject = null,
    code: ?*PyObject = null,
    severity: ?*PyObject = null,
};

fn inside(args: pyoz.Args(struct {
    selector: *PyObject,
    within: *PyObject,
    stop_at: ?*PyObject = null,
    message: ?*PyObject = null,
    code: ?*PyObject = null,
    severity: ?*PyObject = null,
})) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.inside, .{
        .{ "selector", a.selector }, .{ "within", a.within }, .{ "stop_at", a.stop_at },
        .{ "message", a.message },   .{ "code", a.code },     .{ "severity", a.severity },
    }) };
}

fn unique(args: pyoz.Args(struct {
    selector: *PyObject,
    within: ?*PyObject = null,
    message: ?*PyObject = null,
    code: ?*PyObject = null,
    severity: ?*PyObject = null,
})) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.unique, .{ .{ "selector", a.selector }, .{ "within", a.within }, .{ "message", a.message }, .{ "code", a.code }, .{ "severity", a.severity } }) };
}

fn forbid(args: pyoz.Args(Common)) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.forbid, .{ .{ "selector", a.selector }, .{ "message", a.message }, .{ "code", a.code }, .{ "severity", a.severity } }) };
}

fn require(args: pyoz.Args(Common)) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.require, .{ .{ "selector", a.selector }, .{ "message", a.message }, .{ "code", a.code }, .{ "severity", a.severity } }) };
}

fn count(args: pyoz.Args(struct {
    selector: *PyObject,
    exactly: ?*PyObject = null,
    min: ?*PyObject = null,
    max: ?*PyObject = null,
    within: ?*PyObject = null,
    message: ?*PyObject = null,
    code: ?*PyObject = null,
    severity: ?*PyObject = null,
})) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.count, .{
        .{ "selector", a.selector }, .{ "exactly", a.exactly }, .{ "min", a.min },           .{ "max", a.max },
        .{ "message", a.message },   .{ "code", a.code },       .{ "severity", a.severity }, .{ "within", a.within },
    }) };
}

fn scopes(args: pyoz.Args(struct {
    scope: *PyObject,
    define: *PyObject,
    use: *PyObject,
    define_outer: ?*PyObject = null,
    hoist: ?*PyObject = null,
    after: ?*PyObject = null,
    outside: ?*PyObject = null,
    builtins: ?*PyObject = null,
    ordered: ?*PyObject = null,
    namespace: ?*PyObject = null,
    on_undefined: ?*PyObject = null,
    on_redefine: ?*PyObject = null,
    on_unused: ?*PyObject = null,
    on_shadow: ?*PyObject = null,
    on_no_member: ?*PyObject = null,
    members: ?*PyObject = null,
    member_labels: ?*PyObject = null,
    imports: ?*PyObject = null,
    import_all: ?*PyObject = null,
    import_labels: ?*PyObject = null,
    exports: ?*PyObject = null,
    on_no_module: ?*PyObject = null,
    on_no_export: ?*PyObject = null,
    on_unresolved: ?*PyObject = null,
    messages: ?*PyObject = null,
    codes: ?*PyObject = null,
})) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.scopes, .{
        .{ "scope", a.scope },                 .{ "define", a.define },       .{ "use", a.use },
        .{ "define_outer", a.define_outer },   .{ "hoist", a.hoist },         .{ "builtins", a.builtins },
        .{ "ordered", a.ordered },             .{ "namespace", a.namespace }, .{ "on_undefined", a.on_undefined },
        .{ "on_redefine", a.on_redefine },     .{ "on_unused", a.on_unused }, .{ "on_shadow", a.on_shadow },
        .{ "messages", a.messages },           .{ "codes", a.codes },         .{ "after", a.after },
        .{ "on_unresolved", a.on_unresolved }, .{ "members", a.members },     .{ "member_labels", a.member_labels },
        .{ "on_no_member", a.on_no_member },   .{ "imports", a.imports },     .{ "import_all", a.import_all },
        .{ "import_labels", a.import_labels }, .{ "exports", a.exports },     .{ "on_no_module", a.on_no_module },
        .{ "on_no_export", a.on_no_export },   .{ "outside", a.outside },
    }) };
}

fn custom(args: pyoz.Args(struct {
    selector: *PyObject,
    function: *PyObject,
    code: ?*PyObject = null,
})) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.custom, .{ .{ "selector", a.selector }, .{ "function", a.function }, .{ "code", a.code } }) };
}

fn types(args: pyoz.Args(struct {
    basic: ?*PyObject = null,
    coerce: ?*PyObject = null,
    literals: ?*PyObject = null,
    containers: ?*PyObject = null,
    type_names: ?*PyObject = null,
    type_args: ?*PyObject = null,
    optional: ?*PyObject = null,
    variables: ?*PyObject = null,
    functions: ?*PyObject = null,
    structs: ?*PyObject = null,
    binary: ?*PyObject = null,
    unary: ?*PyObject = null,
    calls: ?*PyObject = null,
    index: ?*PyObject = null,
    assigns: ?*PyObject = null,
    returns: ?*PyObject = null,
    conditions: ?*PyObject = null,
    operators: ?*PyObject = null,
    builtins: ?*PyObject = null,
    labels: ?*PyObject = null,
    names: ?*PyObject = null,
    namespace: ?*PyObject = null,
    severity: ?*PyObject = null,
    codes: ?*PyObject = null,
    ignore: ?*PyObject = null,
})) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.types, .{
        .{ "basic", a.basic },           .{ "coerce", a.coerce },       .{ "literals", a.literals },
        .{ "type_names", a.type_names }, .{ "type_args", a.type_args }, .{ "optional", a.optional },
        .{ "variables", a.variables },   .{ "functions", a.functions }, .{ "structs", a.structs },
        .{ "binary", a.binary },         .{ "unary", a.unary },         .{ "calls", a.calls },
        .{ "index", a.index },           .{ "assigns", a.assigns },     .{ "returns", a.returns },
        .{ "conditions", a.conditions }, .{ "operators", a.operators }, .{ "builtins", a.builtins },
        .{ "labels", a.labels },         .{ "namespace", a.namespace }, .{ "severity", a.severity },
        .{ "codes", a.codes },           .{ "ignore", a.ignore },       .{ "containers", a.containers },
        .{ "names", a.names },
    }) };
}

fn flow(args: pyoz.Args(struct {
    sequences: ?*PyObject = null,
    functions: ?*PyObject = null,
    branches: ?*PyObject = null,
    arms: ?*PyObject = null,
    otherwise: ?*PyObject = null,
    loops: ?*PyObject = null,
    forever: ?*PyObject = null,
    at_least_once: ?*PyObject = null,
    exits: ?*PyObject = null,
    breaks: ?*PyObject = null,
    continues: ?*PyObject = null,
    must_return: ?*PyObject = null,
    variables: ?*PyObject = null,
    assigns: ?*PyObject = null,
    labels: ?*PyObject = null,
    namespace: ?*PyObject = null,
    on_unreachable: ?*PyObject = null,
    on_missing_return: ?*PyObject = null,
    on_unassigned: ?*PyObject = null,
    messages: ?*PyObject = null,
    codes: ?*PyObject = null,
})) pyoz.Signature(?Rule, "Rule") {
    const a = args.value;
    return .{ .value = makeRule(.flow, .{
        .{ "sequences", a.sequences },         .{ "functions", a.functions },           .{ "branches", a.branches },
        .{ "arms", a.arms },                   .{ "otherwise", a.otherwise },           .{ "loops", a.loops },
        .{ "forever", a.forever },             .{ "at_least_once", a.at_least_once },   .{ "exits", a.exits },
        .{ "breaks", a.breaks },               .{ "continues", a.continues },           .{ "must_return", a.must_return },
        .{ "variables", a.variables },         .{ "assigns", a.assigns },               .{ "labels", a.labels },
        .{ "namespace", a.namespace },         .{ "on_unreachable", a.on_unreachable }, .{ "on_missing_return", a.on_missing_return },
        .{ "on_unassigned", a.on_unassigned }, .{ "messages", a.messages },             .{ "codes", a.codes },
    }) };
}

// ============================================================================
// Compiled rules
// ============================================================================

const flow_problem_kinds = @typeInfo(flow_mod.ProblemKind).@"enum".fields.len;

/// A compiled flow() rule. Problem kinds index the arrays in the order of
/// flow_mod.ProblemKind: dead, missing_return, unassigned, maybe_unassigned.
const FlowRule = struct {
    /// The scopes() rule whose names it follows ("" = the first one)
    namespace: []const u8,
    sequences: []const Selector,
    functions: []const Selector,
    branches: []const Selector,
    arms: []const Selector,
    otherwise: []const Selector,
    loops: []const Selector,
    forever: []const Selector,
    at_least_once: []const Selector,
    exits: []const Selector,
    breaks: []const Selector,
    continues: []const Selector,
    must_return: []const Selector,
    variables: []const Selector,
    assigns: []const Selector,
    labels: flow_mod.Labels,
    levels: [flow_problem_kinds]Level,
    messages: [flow_problem_kinds][]const u8,
    codes: [flow_problem_kinds][]const u8,
};

const type_problem_kinds = @typeInfo(types_mod.ProblemKind).@"enum".fields.len;

/// A compiled types() rule
const TypeRule = struct {
    /// The scopes() rule whose names it types ("" = the first one)
    namespace: []const u8,
    literals: []const LiteralRule,
    /// Container literals: selector -> constructor name (`list`)
    containers: []const LiteralRule,
    type_names: []const Selector,
    type_args: []const Selector,
    optionals: []const Selector,
    variables: []const Selector,
    functions: []const Selector,
    structs: []const Selector,
    binaries: []const Selector,
    unaries: []const Selector,
    calls: []const Selector,
    indexes: []const Selector,
    assigns: []const Selector,
    returns: []const Selector,
    conditions: []const Selector,
    operators: []const types_mod.Operator,
    basic: []const []const u8,
    coerce: []const [2][]const u8,
    builtins: []const [2][]const u8,
    labels: types_mod.Labels,
    names: types_mod.Names,
    severity: []const u8,
    /// Per types_mod.ProblemKind
    codes: [type_problem_kinds][]const u8,
    ignore: [type_problem_kinds]bool,

    const LiteralRule = struct { selectors: []const Selector, type: []const u8 };
};

/// What to do about a kind of name problem
const Level = enum { ignore, warning, err };

const problem_kinds = @typeInfo(scopes_mod.ProblemKind).@"enum".fields.len;

/// A compiled scopes() rule. Problem kinds index the arrays in the order of
/// scopes_mod.ProblemKind: undefined, redefined, unused, shadowed, no_member,
/// no_module, no_export.
const ScopeRule = struct {
    namespace: []const u8,
    scope: []const Selector,
    define: []const Selector,
    define_outer: []const Selector,
    use: []const Selector,
    hoist: []const Selector,
    /// Definitions visible only after their parent node (the declaration) ends
    after: []const Selector,
    /// Nodes evaluated in the scope outside the one they are written in
    outside: []const Selector,
    /// Member accesses (`target.name`), and the field ids of those two children
    members: []const Selector,
    member_target: u8,
    member_name: u8,
    /// Import statements, and those that import every name of a module
    imports: []const Selector,
    import_all: []const Selector,
    /// Field ids of an import's children: the module, the imported names
    /// and the local alias (0 = the grammar has no such label)
    import_module: u8,
    import_names: u8,
    import_alias: u8,
    /// What a file offers to the others (empty = every top-level definition)
    exports: []const Selector,
    builtins: []const []const u8,
    ordered: bool,
    levels: [problem_kinds]Level,
    messages: [problem_kinds][]const u8,
    codes: [problem_kinds][]const u8,
    /// Called with (node, ctx) for a use that resolves to nothing; a true
    /// result means the language knows the name after all. A strong reference.
    on_unresolved: ?*PyObject = null,
};

const CompiledRule = struct {
    kind: Kind,
    /// The alternatives of the rule's selector (`a, b` or a sequence)
    selectors: []const Selector = &.{},
    /// inside: ancestors that satisfy the rule. unique, count: the ancestors
    /// that delimit a group (default: what the selector's first part matched)
    within: []const Selector = &.{},
    /// inside: ancestors that end the search
    stop_at: []const Selector = &.{},
    /// count: allowed range
    min: u32 = 0,
    max: u32 = std.math.maxInt(u32),
    /// Message template: {text}, {rule} and {count} are replaced
    message: []const u8,
    code: []const u8,
    severity: []const u8,
    /// scopes: its configuration
    scope: ?*const ScopeRule = null,
    /// types: its configuration
    types: ?*const TypeRule = null,
    /// flow: its configuration
    flow: ?*const FlowRule = null,
    /// custom: the Python function to call with (node, ctx); a strong reference
    callback: ?*PyObject = null,
};

/// Everything a Rules object owns, allocated in its arena.
const State = struct {
    arena: std.heap.ArenaAllocator,
    names: selector.Names,
    rules: std.ArrayList(CompiledRule) = .empty,
};

const Finding = struct {
    start: u32,
    end: u32,
    /// Position in the order findings were made (ties in source order)
    order: u32 = 0,
    severity: []const u8,
    code: []const u8,
    message: []const u8,
    /// A related position ("first one is here"), if has_note
    note: []const u8 = "",
    note_start: u32 = 0,
    note_end: u32 = 0,
    has_note: bool = false,

    fn before(_: void, a: Finding, b: Finding) bool {
        return if (a.start != b.start) a.start < b.start else a.order < b.order;
    }
};

/// The broken text of a tree parsed with zgram's recover=True: what the
/// rules say about it would only repeat the syntax errors, or be caused by
/// them (a name defined in text that didn't parse is "undefined" further on).
const Broken = struct {
    /// Error nodes (leaves, so in source order and not overlapping)
    nodes: []const u32,
    /// Where the syntax errors are, sorted (an inserted `;` or `}` leaves
    /// no error node)
    offsets: []const u32,
    /// The words (identifiers) of the broken text
    words: std.StringHashMapUnmanaged(void) = .empty,

    fn init(arena: std.mem.Allocator, tree: *const Tree, error_rule: usize, offsets: []const u32) !*Broken {
        var nodes: std.ArrayList(u32) = .empty;
        for (tree.nodes, 0..) |n, i| {
            if (n.ruleId() >= error_rule) try nodes.append(arena, @intCast(i));
        }
        const self = try arena.create(Broken);
        self.* = .{ .nodes = nodes.items, .offsets = offsets };
        for (nodes.items) |node| {
            const text = tree.text(node);
            var i: usize = 0;
            while (i < text.len) {
                if (!isWord(text[i])) {
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < text.len and isWord(text[i])) i += 1;
                try self.words.put(arena, text[start..i], {});
            }
        }
        return self;
    }

    fn isWord(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
    }

    /// Does [start, end) overlap an error node, or contain a syntax error?
    fn touches(self: *const Broken, tree: *const Tree, start: u32, end: u32) bool {
        // The first error node ending after `start`
        var lo: usize = 0;
        var hi: usize = self.nodes.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (tree.nodes[self.nodes[mid]].text_end <= start) lo = mid + 1 else hi = mid;
        }
        if (lo < self.nodes.len and tree.nodes[self.nodes[lo]].text_start < @max(end, start + 1)) return true;
        const i = std.sort.lowerBound(u32, self.offsets, start, orderU32);
        return i < self.offsets.len and (self.offsets[i] < end or self.offsets[i] == start);
    }

    fn orderU32(a: u32, b: u32) std.math.Order {
        return std.math.order(a, b);
    }
};

// ============================================================================
// Symbol, Analysis, Context: the results of a check
// ============================================================================

fn none() *PyObject {
    py.Py_IncRef(py.Py_None());
    return py.Py_None();
}

fn ownedOrNone(obj: ?*PyObject) *PyObject {
    const o = obj orelse py.Py_None();
    py.Py_IncRef(o);
    return o;
}

/// A name: where it is defined and where it is used.
const Symbol = struct {
    _name: ?*PyObject = null,
    _namespace: ?*PyObject = null,
    /// Defining node's index; -1 for a builtin
    _node: i64 = -1,
    _start: i64 = 0,
    _end: i64 = 0,
    /// Index of the node whose scope it is defined in; -1 = the global scope
    _scope: i64 = -1,
    /// Index of the scope node it names (whose definitions are its members); -1 = none
    _owns: i64 = -1,
    /// (file key, node index) of the definition in another file, for an imported name
    _origin: ?*PyObject = null,
    /// File key, for the local name of an imported module
    _module: ?*PyObject = null,
    /// Its type as text, with a types() rule; None when unknown
    _type: ?*PyObject = null,
    /// list[int]: the nodes that use it, and list[(start, end)]: their spans
    _uses: ?*PyObject = null,
    _use_spans: ?*PyObject = null,

    pub fn __del__(self: *Symbol) void {
        inline for (.{ "_name", "_namespace", "_uses", "_use_spans", "_origin", "_module", "_type" }) |field| {
            if (@field(self, field)) |obj| py.Py_DecRef(obj);
            @field(self, field) = null;
        }
    }

    pub fn get_type(self: *const Symbol) pyoz.Signature(?*PyObject, "str | None") {
        return .{ .value = ownedOrNone(self._type) };
    }

    pub fn get_origin(self: *const Symbol) pyoz.Signature(?*PyObject, "tuple[object, int] | None") {
        return .{ .value = ownedOrNone(self._origin) };
    }

    pub fn get_module(self: *const Symbol) pyoz.Signature(?*PyObject, "object | None") {
        return .{ .value = ownedOrNone(self._module) };
    }

    pub fn get_name(self: *const Symbol) pyoz.Signature(?*PyObject, "str") {
        return .{ .value = ownedOrNone(self._name) };
    }

    pub fn get_namespace(self: *const Symbol) pyoz.Signature(?*PyObject, "str") {
        return .{ .value = ownedOrNone(self._namespace) };
    }

    /// Defined by the rules, not by the file (imported names are not builtins)
    pub fn get_builtin(self: *const Symbol) bool {
        return self._node < 0 and self._origin == null;
    }

    pub fn get_node(self: *const Symbol) ?i64 {
        return if (self._node < 0) null else self._node;
    }

    pub fn get_span(self: *const Symbol) ?struct { i64, i64 } {
        return if (self._node < 0) null else .{ self._start, self._end };
    }

    pub fn get_scope(self: *const Symbol) ?i64 {
        return if (self._scope < 0) null else self._scope;
    }

    pub fn get_owns(self: *const Symbol) ?i64 {
        return if (self._owns < 0) null else self._owns;
    }

    pub fn get_uses(self: *const Symbol) pyoz.Signature(?*PyObject, "list[int]") {
        return .{ .value = ownedOrNone(self._uses) };
    }

    pub fn get_use_spans(self: *const Symbol) pyoz.Signature(?*PyObject, "list[tuple[int, int]]") {
        return .{ .value = ownedOrNone(self._use_spans) };
    }

    pub fn __repr__(self: *const Symbol, buf: []u8) []const u8 {
        var len: py.Py_ssize_t = 0;
        var name: []const u8 = "?";
        if (self._name) |n| {
            if (py.c.PyUnicode_AsUTF8AndSize(n, &len)) |ptr| name = ptr[0..@min(@as(usize, @intCast(len)), 80)] else py.c.PyErr_Clear();
        }
        const uses: i64 = if (self._uses) |u| @intCast(py.c.PyList_Size(u)) else 0;
        if (self._node < 0) return std.fmt.bufPrint(buf, "Symbol('{s}', builtin, {d} uses)", .{ name, uses }) catch buf[0..0];
        return std.fmt.bufPrint(buf, "Symbol('{s}', defined at {d}..{d}, {d} uses)", .{ name, self._start, self._end, uses }) catch buf[0..0];
    }

    pub const __doc__: [*:0]const u8 = "A name found by a scopes() rule: name, namespace, node and span of its definition (None for a builtin), scope (the node index of its scope, None for the global scope), owns (the node index of the scope it names, whose definitions are its members, or None), uses and use_spans. In a project: origin ((file, node index) of the real definition of an imported name) and module (the file an imported module's name stands for).";
};

/// The node index an object stands for: an int, a zgram Node (its `index`)
/// or an AST object built by zgram (its `__znode__`). Sets TypeError and
/// returns null otherwise.
fn nodeIndexOf(obj: *PyObject) ?i64 {
    var source = obj;
    var owned: ?*PyObject = null;
    defer if (owned) |o| py.Py_DecRef(o);
    if (py.c.PyLong_Check(obj) == 0) {
        owned = py.c.PyObject_GetAttrString(obj, "index") orelse blk: {
            py.c.PyErr_Clear();
            break :blk py.c.PyObject_GetAttrString(obj, "__znode__");
        };
        source = owned orelse {
            py.c.PyErr_Clear();
            raise(py.PyExc_TypeError(), "expected a zgram Node, a node index, or an AST object built by zgram", .{});
            return null;
        };
        if (py.c.PyLong_Check(source) == 0) {
            raise(py.PyExc_TypeError(), "expected a zgram Node, a node index, or an AST object built by zgram", .{});
            return null;
        }
    }
    const v = py.c.PyLong_AsLongLong(source);
    if (v == -1 and py.c.PyErr_Occurred() != null) return null;
    return v;
}

/// The types of one check, shared by the analyses of its files: a type that
/// crosses an import is the same id on both sides. Freed with the last one.
const TypeShare = struct {
    arena: std.heap.ArenaAllocator,
    table: types_mod.Table,
    refs: usize = 0,

    fn release(self: *TypeShare) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// The keys of a project's files (strong references), shared by their
/// analyses. Freed with the last one.
const KeyShare = struct {
    refs: usize = 0,
    keys: []*PyObject,

    fn release(self: *KeyShare) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        for (self.keys) |k| py.Py_DecRef(k);
        allocator.free(self.keys);
        allocator.destroy(self);
    }
};

/// What an Analysis keeps from a check: the names found by each scopes()
/// rule, in the arena the check ran in. Symbol objects are made on demand.
const AnalysisData = struct {
    arena: std.heap.ArenaAllocator,
    results: []const Rules.ScopeResult = &.{},
    /// Per result, per symbol: its Symbol object once created
    objects: []const []?*PyObject = &.{},
    /// The tree's nodes (owned by the Tree object the Analysis references)
    nodes: []const tree_mod.FlatNode = &.{},
    /// In a project: every file's key, by file index (kept alive by `key_share`)
    keys: []const *PyObject = &.{},
    key_share: ?*KeyShare = null,
    /// With a types() rule: the file's checker (its types are all worked
    /// out), which scopes() result it typed, and the table its type ids
    /// index, shared by the files of the project
    checker: ?*const types_mod.Checker = null,
    typed_result: usize = 0,
    type_share: ?*TypeShare = null,
    /// The symbols for native code (Analysis.capsule), once asked for
    view: ?*native_abi.AnalysisView = null,

    /// The symbol table as native_abi.AnalysisView, built once in the
    /// arena. Needs the GIL (it reads the project's keys).
    fn nativeView(self: *AnalysisData) !*const native_abi.AnalysisView {
        if (self.view) |v| return v;
        const arena = self.arena.allocator();
        var n_syms: usize = 0;
        var n_uses: usize = 0;
        for (self.results) |result| {
            n_syms += result.result.symbols.items.len;
            for (result.result.symbols.items) |sym| n_uses += sym.uses.len;
        }
        const syms = try arena.alloc(native_abi.SymbolView, n_syms);
        const uses = try arena.alloc(native_abi.Span, n_uses);
        const use_nodes = try arena.alloc(u32, n_uses);
        var si: usize = 0;
        var ui: u32 = 0;
        for (self.results, 0..) |result, r| {
            for (result.result.symbols.items, 0..) |sym, index| {
                var v = native_abi.SymbolView{
                    .name = .{ .ptr = sym.name.ptr, .len = sym.name.len },
                    .namespace = .{ .ptr = result.namespace.ptr, .len = result.namespace.len },
                    .node = sym.node,
                    .scope = sym.scope,
                    .owns = sym.owns,
                    .uses_start = ui,
                    .uses_len = @intCast(sym.uses.len),
                    .flags = if (sym.node == NONE and sym.origin_file == NONE) native_abi.SYMBOL_BUILTIN else 0,
                };
                if (sym.node != NONE) v.def = .{ .start = self.nodes[sym.node].text_start, .end = self.nodes[sym.node].text_end };
                if (sym.origin_file != NONE and sym.origin_file < self.keys.len) {
                    v.origin_key = keyStr(self.keys[sym.origin_file]);
                    v.origin_node = sym.origin_node;
                }
                if (sym.module != NONE and sym.module < self.keys.len) v.module_key = keyStr(self.keys[sym.module]);
                if (self.checker) |checker| {
                    if (r == self.typed_result) {
                        const id = checker.knownSymbol(index);
                        if (id != types_mod.UNKNOWN) {
                            if (self.type_share) |share| {
                                const text = try share.table.format(arena, id);
                                v.type = .{ .ptr = text.ptr, .len = text.len };
                            }
                        }
                    }
                }
                for (sym.uses) |use| {
                    uses[ui] = .{ .start = self.nodes[use].text_start, .end = self.nodes[use].text_end };
                    use_nodes[ui] = use;
                    ui += 1;
                }
                syms[si] = v;
                si += 1;
            }
        }
        const view = try arena.create(native_abi.AnalysisView);
        view.* = .{ .symbol_count = @intCast(n_syms), .symbols = syms.ptr, .uses = uses.ptr, .use_nodes = use_nodes.ptr };
        self.view = view;
        return view;
    }

    /// A project key as a Str: a str's UTF-8 (kept alive by the key share);
    /// none for any other key object.
    fn keyStr(key: *PyObject) native_abi.Str {
        if (!py.PyUnicode_Check(key)) return .{};
        var len: py.Py_ssize_t = 0;
        const ptr = py.c.PyUnicode_AsUTF8AndSize(key, &len) orelse {
            py.c.PyErr_Clear();
            return .{};
        };
        return .{ .ptr = ptr, .len = @intCast(len) };
    }

    /// The spelling of a type id, as a new str; None for unknown.
    fn typeText(self: *const AnalysisData, id: types_mod.TypeId) ?*PyObject {
        const share = self.type_share orelse return none();
        if (id == types_mod.UNKNOWN) return none();
        // A scratch spelling: the table's arena is only for interned types
        var buf: [512]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buf);
        const text = share.table.format(fixed.allocator(), id) catch return py.PyUnicode_FromStringAndSize("...", 3);
        return py.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len));
    }

    fn destroy(self: *AnalysisData) void {
        if (self.type_share) |share| share.release();
        if (self.key_share) |share| share.release();
        for (self.objects) |per_result| {
            for (per_result) |o| {
                if (o) |obj| py.Py_DecRef(obj);
            }
        }
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// The Symbol object of symbol `index` of result `r`: a new reference.
    fn symbol(self: *AnalysisData, r: usize, index: usize) ?*PyObject {
        if (self.objects[r][index]) |obj| {
            py.Py_IncRef(obj);
            return obj;
        }
        const result = self.results[r];
        const sym = result.result.symbols.items[index];
        const uses = py.c.PyList_New(@intCast(sym.uses.len)) orelse return null;
        const spans = py.c.PyList_New(@intCast(sym.uses.len)) orelse {
            py.Py_DecRef(uses);
            return null;
        };
        for (sym.uses, 0..) |use, j| {
            const flat = self.nodes[use];
            _ = py.c.PyList_SetItem(uses, @intCast(j), py.c.PyLong_FromUnsignedLong(use));
            _ = py.c.PyList_SetItem(spans, @intCast(j), py.c.Py_BuildValue("(II)", flat.text_start, flat.text_end));
        }
        var value = Symbol{
            ._name = py.PyUnicode_FromStringAndSize(sym.name.ptr, @intCast(sym.name.len)),
            ._namespace = py.PyUnicode_FromStringAndSize(result.namespace.ptr, @intCast(result.namespace.len)),
            ._scope = if (sym.scope == NONE) -1 else sym.scope,
            ._owns = if (sym.owns == NONE) -1 else sym.owns,
            ._uses = uses,
            ._use_spans = spans,
        };
        if (sym.node != NONE) {
            value._node = sym.node;
            value._start = self.nodes[sym.node].text_start;
            value._end = self.nodes[sym.node].text_end;
        }
        if (sym.origin_file != NONE and sym.origin_file < self.keys.len) {
            value._origin = py.c.Py_BuildValue("(OI)", self.keys[sym.origin_file], sym.origin_node);
        }
        if (sym.module != NONE and sym.module < self.keys.len) {
            value._module = self.keys[sym.module];
            py.Py_IncRef(value._module.?);
        }
        if (self.checker) |checker| {
            if (r == self.typed_result) value._type = self.typeText(checker.knownSymbol(index));
        }
        const obj = Module.toPy(Symbol, value) orelse {
            value.__del__();
            return null;
        };
        self.objects[r][index] = obj;
        py.Py_IncRef(obj);
        return obj;
    }

    /// The Symbol a node defines or uses (later scopes() rules first), or None.
    fn resolve(self: *AnalysisData, node: *PyObject) ?*PyObject {
        const index = nodeIndexOf(node) orelse return null;
        if (index >= 0) {
            var r = self.results.len;
            while (r > 0) {
                r -= 1;
                if (self.results[r].result.symbolOf(@intCast(index))) |sym| return self.symbol(r, sym);
            }
        }
        return none();
    }

    /// Every Symbol, in the order the rules found them.
    fn all(self: *AnalysisData) ?*PyObject {
        const list = py.c.PyList_New(0) orelse return null;
        for (self.results, 0..) |result, r| {
            for (0..result.result.symbols.items.len) |index| {
                const obj = self.symbol(r, index) orelse {
                    py.Py_DecRef(list);
                    return null;
                };
                defer py.Py_DecRef(obj);
                if (py.PyList_Append(list, obj) != 0) {
                    py.Py_DecRef(list);
                    return null;
                }
            }
        }
        return list;
    }
};

/// What Rules.analyze() returns.
const Analysis = struct {
    _diagnostics: ?*PyObject = null,
    _tree: ?*PyObject = null,
    _data: ?*AnalysisData = null,
    /// list[Symbol], once asked for
    _symbols: ?*PyObject = null,

    pub fn __del__(self: *Analysis) void {
        inline for (.{ "_diagnostics", "_symbols" }) |field| {
            if (@field(self, field)) |obj| py.Py_DecRef(obj);
            @field(self, field) = null;
        }
        if (self._data) |d| d.destroy();
        self._data = null;
        // Last: the data points into the tree
        if (self._tree) |obj| py.Py_DecRef(obj);
        self._tree = null;
    }

    pub fn get_diagnostics(self: *const Analysis) pyoz.Signature(?*PyObject, "list[Diagnostic]") {
        return .{ .value = ownedOrNone(self._diagnostics) };
    }

    pub fn get_tree(self: *const Analysis) pyoz.Signature(?*PyObject, "Tree") {
        return .{ .value = ownedOrNone(self._tree) };
    }

    fn symbolList(const_self: *const Analysis) ?*PyObject {
        const self: *Analysis = @constCast(const_self);
        if (self._symbols == null) {
            const data = self._data orelse return py.c.PyList_New(0);
            self._symbols = data.all() orelse return null;
        }
        py.Py_IncRef(self._symbols.?);
        return self._symbols;
    }

    pub fn get_symbols(self: *const Analysis) pyoz.Signature(?*PyObject, "list[Symbol]") {
        return .{ .value = self.symbolList() };
    }

    /// True when no diagnostic is an error.
    pub fn get_ok(self: *const Analysis) bool {
        const list = self._diagnostics orelse return true;
        for (0..@intCast(py.c.PyList_Size(list))) |i| {
            const severity = py.c.PyObject_GetAttrString(py.c.PyList_GetItem(list, @intCast(i)), "severity") orelse {
                py.c.PyErr_Clear();
                continue;
            };
            defer py.Py_DecRef(severity);
            if (py.c.PyUnicode_CompareWithASCIIString(severity, "error") == 0) return false;
        }
        return true;
    }

    fn resolveNode(self: *const Analysis, node: *PyObject) ?*PyObject {
        const data = self._data orelse {
            _ = nodeIndexOf(node) orelse return null;
            return none();
        };
        return data.resolve(node);
    }

    /// The Symbol a node defines or uses, or None.
    pub fn resolve(self: *const Analysis, node: *PyObject) pyoz.Signature(?*PyObject, "Symbol | None") {
        return .{ .value = self.resolveNode(node) };
    }

    fn typeOfNode(self: *const Analysis, node: *PyObject) ?*PyObject {
        const index = nodeIndexOf(node) orelse return null;
        const data = self._data orelse return none();
        const checker = data.checker orelse return none();
        if (index < 0 or index > std.math.maxInt(u32)) return none();
        return data.typeText(checker.known(@intCast(index)));
    }

    /// The type of a node, as text ("int", "list[str]", "Point"), or None
    /// when it is unknown or the rules have no types().
    pub fn type_of(self: *const Analysis, node: *PyObject) pyoz.Signature(?*PyObject, "str | None") {
        return .{ .value = self.typeOfNode(node) };
    }

    /// The Symbol defined or used at a byte offset of the source, or None.
    pub fn at(self: *const Analysis, offset: i64) pyoz.Signature(?*PyObject, "Symbol | None") {
        const data = self._data orelse return .{ .value = none() };
        for (data.results, 0..) |result, r| {
            for (result.result.symbols.items, 0..) |sym, index| {
                var hit = false;
                if (sym.node != NONE) {
                    const flat = data.nodes[sym.node];
                    hit = offset >= flat.text_start and offset <= flat.text_end;
                }
                for (sym.uses) |use| {
                    if (hit) break;
                    const flat = data.nodes[use];
                    hit = offset >= flat.text_start and offset <= flat.text_end;
                }
                if (hit) return .{ .value = data.symbol(r, index) };
            }
        }
        return .{ .value = none() };
    }

    fn capsuleFree(capsule: ?*PyObject) callconv(.c) void {
        const owner: ?*PyObject = @ptrCast(@alignCast(py.c.PyCapsule_GetContext(capsule)));
        if (owner) |obj| py.Py_DecRef(obj);
    }

    /// A PyCapsule "zrules.analysis.v1" pointing to a native_abi.AnalysisView
    /// of the symbols, for native code. The capsule keeps the Analysis alive.
    pub fn get_capsule(const_self: *const Analysis) pyoz.Signature(?*PyObject, "object") {
        const self: *Analysis = @constCast(const_self);
        const view: *const native_abi.AnalysisView = if (self._data) |data|
            data.nativeView() catch return .{ .value = oomObject() }
        else
            &empty_view;
        const capsule = py.c.PyCapsule_New(@constCast(view), native_abi.ANALYSIS_CAPSULE, &capsuleFree) orelse return .{ .value = null };
        const owner = Module.selfObject(Analysis, self);
        py.Py_IncRef(owner);
        _ = py.c.PyCapsule_SetContext(capsule, owner);
        return .{ .value = capsule };
    }

    const empty_view = native_abi.AnalysisView{};

    /// The Symbols visible at a byte offset of the source: what a name
    /// written there could refer to (innermost scope first, an inner name
    /// hiding an outer one, builtins and imported names last).
    pub fn visible(self: *const Analysis, args: pyoz.Args(struct { offset: i64, namespace: ?*PyObject = null })) pyoz.Signature(?*PyObject, "list[Symbol]") {
        const data = self._data orelse return .{ .value = py.c.PyList_New(0) };
        const offset: u32 = @intCast(std.math.clamp(args.value.offset, 0, std.math.maxInt(u32)));
        // The scopes() rule of that namespace (default: the first)
        var r: usize = 0;
        if (args.value.namespace) |ns| {
            if (ns != py.Py_None()) {
                const wanted = utf8(ns, "namespace") orelse return .{ .value = null };
                r = for (data.results, 0..) |result, i| {
                    if (std.mem.eql(u8, result.namespace, wanted)) break i;
                } else {
                    raise(py.PyExc_ValueError(), "no scopes() rule has namespace '{s}'", .{wanted});
                    return .{ .value = null };
                };
            }
        }
        if (r >= data.results.len) return .{ .value = py.c.PyList_New(0) };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const tree = Tree{ .nodes = data.nodes, .input = "", .parents = &.{} };
        const indices = data.results[r].result.visibleAt(arena.allocator(), &tree, offset) catch return .{ .value = oomObject() };
        const list = py.c.PyList_New(@intCast(indices.len)) orelse return .{ .value = null };
        for (indices, 0..) |index, i| {
            const sym = data.symbol(r, index) orelse {
                py.Py_DecRef(list);
                return .{ .value = null };
            };
            _ = py.c.PyList_SetItem(list, @intCast(i), sym);
        }
        return .{ .value = list };
    }

    pub const __doc__: [*:0]const u8 = "The result of Rules.analyze(): diagnostics (in source order), tree, symbols (from scopes() rules), ok (no errors), resolve(node), at(offset) and visible(offset).";
    pub const visible__doc__: [*:0]const u8 = "The Symbols visible at a byte offset of the source, what a name written there could refer to: innermost scope first, an inner name hiding an outer one, builtins and imported names last. namespace= picks the scopes() rule (default: the first).";
    pub const resolve__doc__: [*:0]const u8 = "The Symbol that a node defines or uses, or None. `node` is a zgram Node, a node index, or an AST object built by zgram.";
    pub const resolve__params__ = "node";
    pub const at__doc__: [*:0]const u8 = "The Symbol defined or used at a byte offset of the source, or None.";
    pub const at__params__ = "offset";
    pub const type_of__doc__: [*:0]const u8 = "The type of a node as text ('int', 'list[str]', 'Point'), or None when it is unknown or the rules have no types(). `node` is a zgram Node, a node index, or an AST object built by zgram.";
    pub const type_of__params__ = "node";
};

/// A selector (or a comma-separated list) compiled against a zgram parser's
/// grammar, for use on its own: `match(tree)` gives the matching nodes.
/// (`Selector` in Python.)
const SelectorObject = struct {
    _arena: ?*std.heap.ArenaAllocator = null,
    _names: selector.Names = .{ .rules = &.{}, .fields = &.{}, .actions = &.{} },
    _selectors: []const selector.Selector = &.{},
    /// What `capsule` points to
    _view: native_abi.SelectorView = undefined,

    pub fn __new__(args: pyoz.Args(struct { parser: *PyObject, selector: *PyObject })) ?SelectorObject {
        const arena = allocator.create(std.heap.ArenaAllocator) catch {
            _ = py.c.PyErr_NoMemory();
            return null;
        };
        arena.* = std.heap.ArenaAllocator.init(allocator);
        var self = SelectorObject{ ._arena = arena };
        var ok = false;
        defer if (!ok) self.__del__();
        const a = arena.allocator();
        self._names = .{
            .rules = Rules.nameList(a, args.value.parser, "rules") orelse return null,
            .fields = Rules.nameList(a, args.value.parser, "fields") orelse return null,
            .actions = Rules.nameList(a, args.value.parser, "actions") orelse return null,
        };
        const text = utf8(args.value.selector, "selector") orelse return null;
        var bad: []const u8 = "";
        self._selectors = selector.compileList(a, self._names, text, &bad) catch |e| {
            switch (e) {
                error.UnknownName => raise(py.PyExc_ValueError(), "selector '{s}': the grammar has no rule or class '{s}'", .{ text, bad }),
                error.UnknownField => raise(py.PyExc_ValueError(), "selector '{s}': the grammar has no label '{s}'", .{ text, bad }),
                error.EmptySelector => raise(py.PyExc_ValueError(), "the selector is empty", .{}),
                error.BadSelector => raise(py.PyExc_ValueError(), "selector '{s}' is malformed", .{text}),
                error.OutOfMemory => _ = py.c.PyErr_NoMemory(),
            }
            return null;
        };
        ok = true;
        return self;
    }

    pub fn __del__(self: *SelectorObject) void {
        if (self._arena) |arena| {
            arena.deinit();
            allocator.destroy(arena);
        }
        self._arena = null;
    }

    /// Write the indices of the nodes of `view` that match into `out` (room
    /// for every node), in source order: how many; -1 out of memory; -2 the
    /// tree is from another grammar. Needs no GIL.
    fn matchInto(self: *const SelectorObject, view: *const tree_mod.TreeView, out: [*]u32) i64 {
        var same = view.rule_count == self._names.rules.len and view.field_count == self._names.fields.len;
        if (same) {
            for (self._names.rules, 0..) |name, i| same = same and std.mem.eql(u8, name, view.rule_names.?[i].slice());
        }
        if (!same) return -2;
        const nodes: []const tree_mod.FlatNode = if (view.nodes) |n| n[0..view.node_count] else &.{};
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const tree = Tree{
            .nodes = nodes,
            .input = if (view.input) |p| p[0..view.input_len] else "",
            .parents = Tree.computeParents(arena.allocator(), nodes) catch return -1,
        };
        var found: usize = 0;
        for (nodes, 0..) |node, i| {
            for (self._selectors) |*sel| {
                // (what the last part names, before the whole selector)
                const last = sel.compounds[sel.compounds.len - 1];
                if (last.rules) |rules| {
                    if (node.ruleId() >= rules.len or !rules[node.ruleId()]) continue;
                }
                if (last.field != 0 and node.fieldId() != last.field) continue;
                if (!sel.matches(&tree, @intCast(i), null)) continue;
                out[found] = @intCast(i);
                found += 1;
                break;
            }
        }
        return @intCast(found);
    }

    fn nativeMatch(ctx: *const anyopaque, view: *const tree_mod.TreeView, out: [*]u32) callconv(.c) i64 {
        const self: *const SelectorObject = @ptrCast(@alignCast(ctx));
        return self.matchInto(view, out);
    }

    fn capsuleFree(capsule: ?*PyObject) callconv(.c) void {
        const owner: ?*PyObject = @ptrCast(@alignCast(py.c.PyCapsule_GetContext(capsule)));
        if (owner) |obj| py.Py_DecRef(obj);
    }

    /// A PyCapsule "zrules.selector.v1" pointing to a native_abi.SelectorView:
    /// the match function for native code. The capsule keeps the selector alive.
    pub fn get_capsule(const_self: *const SelectorObject) pyoz.Signature(?*PyObject, "object") {
        const self: *SelectorObject = @constCast(const_self);
        self._view = .{ .ctx = self, .match = &nativeMatch };
        const capsule = py.c.PyCapsule_New(&self._view, native_abi.SELECTOR_CAPSULE, &capsuleFree) orelse return .{ .value = null };
        const owner = Module.selfObject(SelectorObject, self);
        py.Py_IncRef(owner);
        _ = py.c.PyCapsule_SetContext(capsule, owner);
        return .{ .value = capsule };
    }

    /// The indices of the nodes that match, in source order.
    pub fn match(self: *const SelectorObject, source: *PyObject) pyoz.Signature(?*PyObject, "list[int]") {
        const tree_obj = (if (py.c.PyObject_HasAttrString(source, "capsule") != 0) blk: {
            py.Py_IncRef(source);
            break :blk source;
        } else py.c.PyObject_GetAttrString(source, "tree")) orelse {
            py.c.PyErr_Clear();
            raise(py.PyExc_TypeError(), "expected a zgram Tree or Node", .{});
            return .{ .value = null };
        };
        defer py.Py_DecRef(tree_obj);
        const capsule = py.c.PyObject_GetAttrString(tree_obj, "capsule") orelse return .{ .value = null };
        defer py.Py_DecRef(capsule);
        const view: *const tree_mod.TreeView = @ptrCast(@alignCast(py.c.PyCapsule_GetPointer(capsule, tree_mod.CAPSULE_NAME) orelse return .{ .value = null }));
        if (view.abi != tree_mod.TREE_ABI) {
            raise(py.PyExc_RuntimeError(), "this zrules reads zgram trees with TREE_ABI {d}, but the tree has {d}: upgrade zrules or zgram", .{ tree_mod.TREE_ABI, view.abi });
            return .{ .value = null };
        }
        const out = allocator.alloc(u32, view.node_count) catch return .{ .value = oomObject() };
        defer allocator.free(out);
        const n = self.matchInto(view, out.ptr);
        if (n == -2) {
            raise(py.PyExc_ValueError(), "the tree was parsed with a different grammar than the selector was compiled against", .{});
            return .{ .value = null };
        }
        if (n < 0) return .{ .value = oomObject() };
        const found = out[0..@intCast(n)];
        const list = py.c.PyList_New(@intCast(found.len)) orelse return .{ .value = null };
        for (found, 0..) |node, i| {
            const item = py.c.PyLong_FromUnsignedLong(node) orelse {
                py.Py_DecRef(list);
                return .{ .value = null };
            };
            _ = py.c.PyList_SetItem(list, @intCast(i), item);
        }
        return .{ .value = list };
    }

    pub const __doc__: [*:0]const u8 = "Selector(parser, selector): a selector (or a comma-separated list) compiled against a zgram parser's grammar. match(tree) returns the indices of the nodes that match, in source order.";
    pub const match__doc__: [*:0]const u8 = "The indices of the nodes of a zgram Tree (or of a Node's tree) that match, in source order.";
    pub const match__params__ = "tree";
};

/// What a custom rule's function receives as its second argument. Only
/// usable while the check that created it is running.
const Context = struct {
    _run: ?*Rules.Run = null,
    /// The Analysis being built (a strong reference): symbols and tree
    _analysis: ?*PyObject = null,
    /// Code of findings reported without one: the running rule's
    _code: []const u8 = "custom",

    pub fn __del__(self: *Context) void {
        if (self._analysis) |obj| py.Py_DecRef(obj);
        self._analysis = null;
    }

    fn analysis(self: *const Context) ?*const Analysis {
        return Module.fromPy(*const Analysis, self._analysis orelse return null) catch null;
    }

    const ReportArgs = struct { node: *PyObject, message: []const u8, code: ?[]const u8 = null };

    fn report(self: *Context, severity: []const u8, a: ReportArgs) ?*PyObject {
        const run = self._run orelse {
            raise(py.PyExc_RuntimeError(), "this context's check has finished", .{});
            return null;
        };
        var start: c_longlong = 0;
        var end: c_longlong = 0;
        if (py.PyTuple_Check(a.node)) {
            // An explicit (start, end) span
            if (py.c.PyArg_ParseTuple(a.node, "LL", &start, &end) == 0) return null;
        } else {
            const index = nodeIndexOf(a.node) orelse return null;
            if (index < 0 or index >= run.tree.nodes.len) {
                raise(py.PyExc_IndexError(), "node index {d} is out of range", .{index});
                return null;
            }
            const flat = run.tree.nodes[@intCast(index)];
            start = flat.text_start;
            end = flat.text_end;
        }
        if (start < 0 or end < start or end > std.math.maxInt(u32)) {
            raise(py.PyExc_ValueError(), "span must be 0 <= start <= end", .{});
            return null;
        }
        _ = run.add(.{
            .start = @intCast(start),
            .end = @intCast(end),
            .severity = severity,
            .code = run.arena.dupe(u8, a.code orelse self._code) catch return oomObject(),
            .message = run.arena.dupe(u8, a.message) catch return oomObject(),
        }) catch return oomObject();
        return none();
    }

    pub fn @"error"(self: *Context, args: pyoz.Args(ReportArgs)) pyoz.Signature(?*PyObject, "None") {
        return .{ .value = self.report("error", args.value) };
    }

    pub fn warning(self: *Context, args: pyoz.Args(ReportArgs)) pyoz.Signature(?*PyObject, "None") {
        return .{ .value = self.report("warning", args.value) };
    }

    pub fn note(self: *Context, args: pyoz.Args(ReportArgs)) pyoz.Signature(?*PyObject, "None") {
        return .{ .value = self.report("note", args.value) };
    }

    /// The Symbol a node defines or uses, or None.
    pub fn resolve(self: *const Context, node: *PyObject) pyoz.Signature(?*PyObject, "Symbol | None") {
        const a = self.analysis() orelse return .{ .value = none() };
        return .{ .value = a.resolveNode(node) };
    }

    /// The type of a node as text, or None when unknown.
    pub fn type_of(self: *const Context, node: *PyObject) pyoz.Signature(?*PyObject, "str | None") {
        const a = self.analysis() orelse return .{ .value = none() };
        return .{ .value = a.typeOfNode(node) };
    }

    pub fn get_tree(self: *const Context) pyoz.Signature(?*PyObject, "Tree") {
        const a = self.analysis() orelse return .{ .value = none() };
        return .{ .value = ownedOrNone(a._tree) };
    }

    pub fn get_symbols(self: *const Context) pyoz.Signature(?*PyObject, "list[Symbol]") {
        const a = self.analysis() orelse return .{ .value = py.c.PyList_New(0) };
        return .{ .value = a.symbolList() };
    }

    pub const __doc__: [*:0]const u8 = "Passed to custom rule functions: error(node, message, code=None), warning(...), note(...), resolve(node), tree and symbols. `node` is a zgram Node, a node index, an AST object built by zgram, or a (start, end) span.";
    pub const error__doc__: [*:0]const u8 = "Report an error at a node (or a (start, end) span).";
    pub const warning__doc__: [*:0]const u8 = "Report a warning at a node (or a (start, end) span).";
    pub const note__doc__: [*:0]const u8 = "Report a note at a node (or a (start, end) span).";
    pub const resolve__doc__: [*:0]const u8 = "The Symbol that a node defines or uses, or None.";
    pub const resolve__params__ = "node";
};

fn oomObject() ?*PyObject {
    _ = py.c.PyErr_NoMemory();
    return null;
}

// ============================================================================
// Project: the result of checking several files together
// ============================================================================

const Project = struct {
    /// dict: file key -> Analysis, in the order the files were given
    _analyses: ?*PyObject = null,

    pub fn __del__(self: *Project) void {
        if (self._analyses) |obj| py.Py_DecRef(obj);
        self._analyses = null;
    }

    pub fn __len__(self: *const Project) i64 {
        return if (self._analyses) |a| @intCast(py.c.PyDict_Size(a)) else 0;
    }

    /// The Analysis of one file.
    pub fn file(self: *const Project, key: *PyObject) pyoz.Signature(?*PyObject, "Analysis") {
        const found = py.c.PyDict_GetItemWithError(self._analyses orelse return .{ .value = null }, key);
        if (found == null) {
            if (py.c.PyErr_Occurred() == null) py.c.PyErr_SetObject(py.PyExc_KeyError(), key);
            return .{ .value = null };
        }
        return .{ .value = ownedOrNone(found) };
    }

    pub fn get_files(self: *const Project) pyoz.Signature(?*PyObject, "list") {
        return .{ .value = py.c.PyDict_Keys(self._analyses orelse return .{ .value = py.c.PyList_New(0) }) };
    }

    /// dict: file key -> list[Diagnostic]
    pub fn get_diagnostics(self: *const Project) pyoz.Signature(?*PyObject, "dict[object, list[Diagnostic]]") {
        const out = py.c.PyDict_New() orelse return .{ .value = null };
        const analyses = self._analyses orelse return .{ .value = out };
        var pos: py.Py_ssize_t = 0;
        var key: ?*PyObject = null;
        var value: ?*PyObject = null;
        while (py.c.PyDict_Next(analyses, &pos, &key, &value) != 0) {
            const list = py.c.PyObject_GetAttrString(value, "diagnostics") orelse {
                py.Py_DecRef(out);
                return .{ .value = null };
            };
            defer py.Py_DecRef(list);
            if (py.PyDict_SetItem(out, key.?, list) != 0) {
                py.Py_DecRef(out);
                return .{ .value = null };
            }
        }
        return .{ .value = out };
    }

    /// True when no file has an error.
    pub fn get_ok(self: *const Project) bool {
        const analyses = self._analyses orelse return true;
        var pos: py.Py_ssize_t = 0;
        var key: ?*PyObject = null;
        var value: ?*PyObject = null;
        while (py.c.PyDict_Next(analyses, &pos, &key, &value) != 0) {
            const analysis = Module.fromPy(*const Analysis, value.?) catch {
                py.c.PyErr_Clear();
                continue;
            };
            if (!analysis.get_ok()) return false;
        }
        return true;
    }

    /// The Symbol an imported name really refers to, in the file that
    /// defines it; the symbol itself if it isn't imported.
    pub fn origin(self: *const Project, symbol: *PyObject) pyoz.Signature(?*PyObject, "Symbol") {
        const sym = Module.fromPy(*const Symbol, symbol) catch {
            py.c.PyErr_Clear();
            raise(py.PyExc_TypeError(), "origin() takes a Symbol", .{});
            return .{ .value = null };
        };
        const where = sym._origin orelse {
            py.Py_IncRef(symbol);
            return .{ .value = symbol };
        };
        const analysis = py.c.PyDict_GetItemWithError(self._analyses orelse return .{ .value = null }, py.PyTuple_GetItem(where, 0).?) orelse {
            if (py.c.PyErr_Occurred() == null) raise(py.PyExc_KeyError(), "the symbol comes from a file that is not in this project", .{});
            return .{ .value = null };
        };
        const found = py.c.PyObject_CallMethod(analysis, "resolve", "O", py.PyTuple_GetItem(where, 1).?) orelse return .{ .value = null };
        // Follow re-exports to the end
        if (found != py.Py_None() and found != symbol) {
            defer py.Py_DecRef(found);
            return self.origin(found);
        }
        return .{ .value = found };
    }

    pub const __doc__: [*:0]const u8 = "The result of Rules.analyze_project(): file(key) gives a file's Analysis; files, diagnostics (per file), ok, and origin(symbol) to follow an imported name to its definition.";
    pub const file__doc__: [*:0]const u8 = "The Analysis of one file. Raises KeyError for a key that is not in the project.";
    pub const file__params__ = "key";
    pub const origin__doc__: [*:0]const u8 = "The Symbol an imported name really refers to, in the file that defines it (following re-exports); the symbol itself if it isn't imported.";
    pub const origin__params__ = "symbol";
};

// ============================================================================
// Rules
// ============================================================================

const Rules = struct {
    _state: ?*State = null,
    /// The parser the rules were compiled against (strong reference)
    _parser: ?*PyObject = null,

    // ── Construction ──

    /// Call `parser.<method>()` and copy the list of str (None -> "") into `arena`.
    fn nameList(arena: std.mem.Allocator, parser: *PyObject, method: [*:0]const u8) ?[]const []const u8 {
        const list = py.c.PyObject_CallMethod(parser, method, null) orelse {
            py.c.PyErr_Clear();
            raise(py.PyExc_TypeError(), "Rules() needs a zgram parser (no usable {s}() method)", .{method});
            return null;
        };
        defer py.Py_DecRef(list);
        return strings(arena, list, "a name", true);
    }

    /// A sequence of str copied into `arena` (None -> "" when `allow_none`).
    fn strings(arena: std.mem.Allocator, seq: *PyObject, what: []const u8, allow_none: bool) ?[]const []const u8 {
        if (py.PyUnicode_Check(seq)) {
            const one = arena.alloc([]const u8, 1) catch return oomSlice();
            one[0] = arena.dupe(u8, utf8(seq, what) orelse return null) catch return oomSlice();
            return one;
        }
        const n = py.c.PySequence_Size(seq);
        if (n < 0) {
            py.c.PyErr_Clear();
            raise(py.PyExc_TypeError(), "{s} must be a str or a sequence of str", .{what});
            return null;
        }
        const out = arena.alloc([]const u8, @intCast(n)) catch return oomSlice();
        for (out, 0..) |*slot, i| {
            const item = py.c.PySequence_GetItem(seq, @intCast(i)) orelse return null;
            defer py.Py_DecRef(item);
            if (allow_none and item == py.Py_None()) {
                slot.* = "";
            } else {
                slot.* = arena.dupe(u8, utf8(item, what) orelse return null) catch return oomSlice();
            }
        }
        return out;
    }

    fn oomSlice() ?[]const []const u8 {
        _ = py.c.PyErr_NoMemory();
        return null;
    }

    /// Compile a selector list (`a, b`), raising ValueError with its text on failure.
    fn compileText(state: *State, obj: *PyObject, what: []const u8, out: *std.ArrayList(Selector)) bool {
        const text = utf8(obj, what) orelse return false;
        var bad: []const u8 = "";
        const list = selector.compileList(state.arena.allocator(), state.names, text, &bad) catch |e| {
            switch (e) {
                error.UnknownName => raise(py.PyExc_ValueError(), "selector '{s}': the grammar has no rule or class '{s}'", .{ text, bad }),
                error.UnknownField => raise(py.PyExc_ValueError(), "selector '{s}': the grammar has no label '{s}'", .{ text, bad }),
                error.EmptySelector => raise(py.PyExc_ValueError(), "{s} is empty", .{what}),
                error.BadSelector => raise(py.PyExc_ValueError(), "selector '{s}' is malformed", .{text}),
                error.OutOfMemory => _ = py.c.PyErr_NoMemory(),
            }
            return false;
        };
        out.appendSlice(state.arena.allocator(), list) catch {
            _ = py.c.PyErr_NoMemory();
            return false;
        };
        return true;
    }

    /// Selectors from a str (one, or several separated by commas) or a
    /// sequence of such str; none when absent.
    fn compileSelectors(state: *State, obj: ?*PyObject, what: []const u8) ?[]const Selector {
        const o = obj orelse return &.{};
        var out: std.ArrayList(Selector) = .empty;
        if (py.PyUnicode_Check(o)) {
            if (!compileText(state, o, what, &out)) return null;
            return out.items;
        }
        const n = py.c.PySequence_Size(o);
        if (n < 0) {
            py.c.PyErr_Clear();
            raise(py.PyExc_TypeError(), "{s} must be a str or a sequence of str", .{what});
            return null;
        }
        for (0..@intCast(n)) |i| {
            const item = py.c.PySequence_GetItem(o, @intCast(i)) orelse return null;
            defer py.Py_DecRef(item);
            if (!compileText(state, item, what, &out)) return null;
        }
        return out.items;
    }

    /// A str argument copied into the arena, or `default` when absent.
    fn textArg(state: *State, args: *PyObject, key: [*:0]const u8, default: []const u8) ?[]const u8 {
        const obj = py.c.PyDict_GetItemString(args, key) orelse return default;
        const text = utf8(obj, std.mem.span(key)) orelse return null;
        return state.arena.allocator().dupe(u8, text) catch {
            _ = py.c.PyErr_NoMemory();
            return null;
        };
    }

    /// A non-negative int argument, or null when absent. Sets `failed` on a bad value.
    fn intArg(args: *PyObject, key: [*:0]const u8, failed: *bool) ?u32 {
        const obj = py.c.PyDict_GetItemString(args, key) orelse return null;
        const v = py.c.PyLong_AsLongLong(obj);
        if (v == -1 and py.c.PyErr_Occurred() != null) {
            failed.* = true;
            return null;
        }
        if (v < 0 or v > std.math.maxInt(u32)) {
            raise(py.PyExc_ValueError(), "{s} must be a non-negative int", .{std.mem.span(key)});
            failed.* = true;
            return null;
        }
        return @intCast(v);
    }

    const problem_keys = [problem_kinds][:0]const u8{ "undefined", "redefined", "unused", "shadowed", "no_member", "no_module", "no_export" };

    /// messages= / codes=: a dict overriding some of `defaults`, by problem kind.
    fn problemTexts(state: *State, args: *PyObject, key: [*:0]const u8, defaults: [problem_kinds][]const u8) ?[problem_kinds][]const u8 {
        var out = defaults;
        const dict = py.c.PyDict_GetItemString(args, key) orelse return out;
        if (!py.PyDict_Check(dict)) {
            raise(py.PyExc_TypeError(), "{s} must be a dict", .{std.mem.span(key)});
            return null;
        }
        if (py.c.PyDict_Size(dict) > 0) {
            var known: py.Py_ssize_t = 0;
            for (problem_keys, 0..) |k, i| {
                const value = py.c.PyDict_GetItemString(dict, k) orelse continue;
                known += 1;
                out[i] = state.arena.allocator().dupe(u8, utf8(value, k) orelse return null) catch {
                    _ = py.c.PyErr_NoMemory();
                    return null;
                };
            }
            if (known != py.c.PyDict_Size(dict)) {
                raise(py.PyExc_ValueError(), "{s}: the keys are 'undefined', 'redefined', 'unused', 'shadowed', 'no_member', 'no_module' and 'no_export'", .{std.mem.span(key)});
                return null;
            }
        }
        return out;
    }

    fn levelArg(args: *PyObject, key: [*:0]const u8, default: Level) ?Level {
        const obj = py.c.PyDict_GetItemString(args, key) orelse return default;
        const text = utf8(obj, std.mem.span(key)) orelse return null;
        if (std.mem.eql(u8, text, "error")) return .err;
        if (std.mem.eql(u8, text, "warning")) return .warning;
        if (std.mem.eql(u8, text, "ignore")) return .ignore;
        raise(py.PyExc_ValueError(), "{s} must be 'error', 'warning' or 'ignore'", .{std.mem.span(key)});
        return null;
    }

    fn compileScopes(state: *State, args: *PyObject) ?*const ScopeRule {
        const arena = state.arena.allocator();
        const sr = arena.create(ScopeRule) catch {
            _ = py.c.PyErr_NoMemory();
            return null;
        };
        const ordered = if (py.c.PyDict_GetItemString(args, "ordered")) |o| py.c.PyObject_IsTrue(o) != 0 else true;
        const builtins: []const []const u8 = if (py.c.PyDict_GetItemString(args, "builtins")) |b| strings(arena, b, "builtins", false) orelse return null else &.{};
        // Labels of a member access's two children: ("target", "name") by default
        var member_labels = [2][]const u8{ "target", "name" };
        if (py.c.PyDict_GetItemString(args, "member_labels")) |labels| {
            const given = strings(arena, labels, "member_labels", false) orelse return null;
            if (given.len != 2) {
                raise(py.PyExc_ValueError(), "member_labels must be two labels: (target, name)", .{});
                return null;
            }
            member_labels = .{ given[0], given[1] };
        }
        const member_selectors = compileSelectors(state, py.c.PyDict_GetItemString(args, "members"), "members") orelse return null;
        var member_ids = [2]u8{ 0, 0 };
        if (member_selectors.len != 0) {
            for (member_labels, 0..) |label, i| {
                for (state.names.fields, 1..) |f, id| {
                    if (std.mem.eql(u8, f, label)) member_ids[i] = @intCast(id);
                }
                if (member_ids[i] == 0) {
                    raise(py.PyExc_ValueError(), "members: the grammar has no label '{s}' (set member_labels=(target, name))", .{label});
                    return null;
                }
            }
        }
        // Labels of an import's children: ("module", "names", "alias") by default
        var import_labels = [3][]const u8{ "module", "names", "alias" };
        if (py.c.PyDict_GetItemString(args, "import_labels")) |labels| {
            const given = strings(arena, labels, "import_labels", false) orelse return null;
            if (given.len != 3) {
                raise(py.PyExc_ValueError(), "import_labels must be three labels: (module, names, alias)", .{});
                return null;
            }
            import_labels = .{ given[0], given[1], given[2] };
        }
        const import_selectors = compileSelectors(state, py.c.PyDict_GetItemString(args, "imports"), "imports") orelse return null;
        const import_all_selectors = compileSelectors(state, py.c.PyDict_GetItemString(args, "import_all"), "import_all") orelse return null;
        var import_ids = [3]u8{ 0, 0, 0 };
        for (import_labels, 0..) |label, i| {
            for (state.names.fields, 1..) |f, id| {
                if (std.mem.eql(u8, f, label)) import_ids[i] = @intCast(id);
            }
        }
        if ((import_selectors.len != 0 or import_all_selectors.len != 0) and import_ids[0] == 0) {
            raise(py.PyExc_ValueError(), "imports: the grammar has no label '{s}' (set import_labels=(module, names, alias))", .{import_labels[0]});
            return null;
        }
        sr.* = .{
            .namespace = textArg(state, args, "namespace", "name") orelse return null,
            .imports = import_selectors,
            .import_all = import_all_selectors,
            .import_module = import_ids[0],
            .import_names = import_ids[1],
            .import_alias = import_ids[2],
            .exports = compileSelectors(state, py.c.PyDict_GetItemString(args, "exports"), "exports") orelse return null,
            .members = member_selectors,
            .member_target = member_ids[0],
            .member_name = member_ids[1],
            .scope = compileSelectors(state, py.c.PyDict_GetItemString(args, "scope"), "scope") orelse return null,
            .define = compileSelectors(state, py.c.PyDict_GetItemString(args, "define"), "define") orelse return null,
            .define_outer = compileSelectors(state, py.c.PyDict_GetItemString(args, "define_outer"), "define_outer") orelse return null,
            .use = compileSelectors(state, py.c.PyDict_GetItemString(args, "use"), "use") orelse return null,
            .hoist = compileSelectors(state, py.c.PyDict_GetItemString(args, "hoist"), "hoist") orelse return null,
            .after = compileSelectors(state, py.c.PyDict_GetItemString(args, "after"), "after") orelse return null,
            .outside = compileSelectors(state, py.c.PyDict_GetItemString(args, "outside"), "outside") orelse return null,
            .builtins = builtins,
            .ordered = ordered,
            .levels = .{
                levelArg(args, "on_undefined", .err) orelse return null,
                levelArg(args, "on_redefine", .err) orelse return null,
                levelArg(args, "on_unused", .ignore) orelse return null,
                levelArg(args, "on_shadow", .ignore) orelse return null,
                levelArg(args, "on_no_member", .err) orelse return null,
                levelArg(args, "on_no_module", .err) orelse return null,
                levelArg(args, "on_no_export", .err) orelse return null,
            },
            .messages = problemTexts(state, args, "messages", .{
                "undefined name '{text}'",
                "'{text}' is already defined",
                "'{text}' is never used",
                "'{text}' shadows an outer definition",
                "'{owner}' has no member '{text}'",
                "module '{text}' not found",
                "module '{owner}' has no '{text}'",
            }) orelse return null,
            .codes = problemTexts(state, args, "codes", .{ "undefined-name", "redefined-name", "unused-name", "shadowed-name", "no-member", "no-module", "no-export" }) orelse return null,
        };
        if (py.c.PyDict_GetItemString(args, "on_unresolved")) |f| {
            if (py.c.PyCallable_Check(f) == 0) {
                raise(py.PyExc_TypeError(), "on_unresolved must be callable: on_unresolved(node, ctx)", .{});
                return null;
            }
            py.Py_IncRef(f);
            sr.on_unresolved = f;
        }
        return sr;
    }

    /// A dict of str -> str as pairs copied into the arena; none when absent.
    fn textPairs(state: *State, args: *PyObject, key: [*:0]const u8) ?[]const [2][]const u8 {
        const dict = py.c.PyDict_GetItemString(args, key) orelse return &.{};
        if (!py.PyDict_Check(dict)) {
            raise(py.PyExc_TypeError(), "{s} must be a dict of str -> str", .{std.mem.span(key)});
            return null;
        }
        const arena = state.arena.allocator();
        var out: std.ArrayList([2][]const u8) = .empty;
        var pos: py.Py_ssize_t = 0;
        var k: ?*PyObject = null;
        var v: ?*PyObject = null;
        while (py.c.PyDict_Next(dict, &pos, &k, &v) != 0) {
            const name = arena.dupe(u8, utf8(k.?, std.mem.span(key)) orelse return null) catch return oomPairs();
            const value = arena.dupe(u8, utf8(v.?, std.mem.span(key)) orelse return null) catch return oomPairs();
            out.append(arena, .{ name, value }) catch return oomPairs();
        }
        return out.items;
    }

    fn oomPairs() ?[]const [2][]const u8 {
        _ = py.c.PyErr_NoMemory();
        return null;
    }

    /// Is `text` a type as types_mod.Table.parse reads it? Raises ValueError if not.
    fn validType(scratch: *types_mod.Table, text: []const u8, what: []const u8) bool {
        _ = scratch.parse(text) catch |e| {
            if (e == error.OutOfMemory) _ = py.c.PyErr_NoMemory() else raise(py.PyExc_ValueError(), "{s}: '{s}' is not a type (write int, list[int], str?, fn(int, str) -> bool)", .{ what, text });
            return false;
        };
        return true;
    }

    fn oomTypes() ?*const TypeRule {
        _ = py.c.PyErr_NoMemory();
        return null;
    }

    fn compileTypes(state: *State, args: *PyObject) ?*const TypeRule {
        const arena = state.arena.allocator();
        const tr = arena.create(TypeRule) catch return oomTypes();
        // Types are only checked for syntax here; a throwaway table does that
        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();
        var scratch = types_mod.Table.init(scratch_arena.allocator()) catch {
            _ = py.c.PyErr_NoMemory();
            return null;
        };

        // literals: selector -> type
        var literals: std.ArrayList(TypeRule.LiteralRule) = .empty;
        if (py.c.PyDict_GetItemString(args, "literals")) |dict| {
            if (!py.PyDict_Check(dict)) {
                raise(py.PyExc_TypeError(), "literals must be a dict of selector -> type", .{});
                return null;
            }
            var pos: py.Py_ssize_t = 0;
            var k: ?*PyObject = null;
            var v: ?*PyObject = null;
            while (py.c.PyDict_Next(dict, &pos, &k, &v) != 0) {
                const selectors = compileSelectors(state, k, "literals") orelse return null;
                const text = arena.dupe(u8, utf8(v.?, "a literal's type") orelse return null) catch return oomTypes();
                if (!validType(&scratch, text, "literals")) return null;
                literals.append(arena, .{ .selectors = selectors, .type = text }) catch return oomTypes();
            }
        }

        // containers: selector -> constructor name
        var containers: std.ArrayList(TypeRule.LiteralRule) = .empty;
        if (py.c.PyDict_GetItemString(args, "containers")) |dict| {
            if (!py.PyDict_Check(dict)) {
                raise(py.PyExc_TypeError(), "containers must be a dict of selector -> name", .{});
                return null;
            }
            var pos: py.Py_ssize_t = 0;
            var k: ?*PyObject = null;
            var v: ?*PyObject = null;
            while (py.c.PyDict_Next(dict, &pos, &k, &v) != 0) {
                const selectors = compileSelectors(state, k, "containers") orelse return null;
                const name = arena.dupe(u8, utf8(v.?, "a container's name") orelse return null) catch return oomTypes();
                containers.append(arena, .{ .selectors = selectors, .type = name }) catch return oomTypes();
            }
        }

        // operators: op -> rows of (left, right, result), or (operand, result) for a unary one
        var operators: std.ArrayList(types_mod.Operator) = .empty;
        if (py.c.PyDict_GetItemString(args, "operators")) |dict| {
            if (!py.PyDict_Check(dict)) {
                raise(py.PyExc_TypeError(), "operators must be a dict of operator -> rows", .{});
                return null;
            }
            var pos: py.Py_ssize_t = 0;
            var k: ?*PyObject = null;
            var v: ?*PyObject = null;
            while (py.c.PyDict_Next(dict, &pos, &k, &v) != 0) {
                const op = arena.dupe(u8, utf8(k.?, "an operator") orelse return null) catch return oomTypes();
                const n_rows = py.c.PySequence_Size(v);
                if (n_rows < 0 or py.PyUnicode_Check(v.?)) {
                    py.c.PyErr_Clear();
                    raise(py.PyExc_TypeError(), "operators['{s}'] must be a list of rows: (left, right, result) or (operand, result)", .{op});
                    return null;
                }
                for (0..@intCast(n_rows)) |i| {
                    const row_obj = py.c.PySequence_GetItem(v, @intCast(i)) orelse return null;
                    defer py.Py_DecRef(row_obj);
                    const row = strings(arena, row_obj, "an operator row", false) orelse return null;
                    if (py.PyUnicode_Check(row_obj) or (row.len != 2 and row.len != 3)) {
                        raise(py.PyExc_ValueError(), "operators['{s}']: a row is (left, right, result) or (operand, result)", .{op});
                        return null;
                    }
                    for (row) |text| {
                        if (!std.mem.eql(u8, text, "T") and !validType(&scratch, text, "operators")) return null;
                    }
                    operators.append(arena, if (row.len == 3)
                        .{ .op = op, .left = row[0], .right = row[1], .result = row[2] }
                    else
                        .{ .op = op, .right = row[0], .result = row[1] }) catch return oomTypes();
                }
            }
        }

        const coerce = textPairs(state, args, "coerce") orelse return null;
        for (coerce) |pair| {
            if (!validType(&scratch, pair[0], "coerce") or !validType(&scratch, pair[1], "coerce")) return null;
        }
        const builtins = textPairs(state, args, "builtins") orelse return null;
        for (builtins) |pair| {
            if (!validType(&scratch, pair[1], "builtins")) return null;
        }

        // Which label each child is read through: its role's name, unless overridden
        var labels = types_mod.Labels{};
        const overrides = textPairs(state, args, "labels") orelse return null;
        inline for (@typeInfo(types_mod.Labels).@"struct".fields) |field| {
            var label: []const u8 = field.name;
            for (overrides) |pair| {
                if (std.mem.eql(u8, pair[0], field.name)) label = pair[1];
            }
            for (state.names.fields, 1..) |f, id| {
                if (std.mem.eql(u8, f, label)) @field(labels, field.name) = @intCast(id);
            }
        }
        for (overrides) |pair| {
            var known = false;
            inline for (@typeInfo(types_mod.Labels).@"struct".fields) |field| {
                if (std.mem.eql(u8, pair[0], field.name)) known = true;
            }
            if (!known) {
                raise(py.PyExc_ValueError(), "labels: unknown role '{s}'", .{pair[0]});
                return null;
            }
        }

        // What the language calls the types the checker itself needs
        var type_names = types_mod.Names{};
        for (textPairs(state, args, "names") orelse return null) |pair| {
            var known = false;
            inline for (@typeInfo(types_mod.Names).@"struct".fields) |field| {
                if (std.mem.eql(u8, pair[0], field.name)) {
                    @field(type_names, field.name) = pair[1];
                    known = true;
                }
            }
            if (!known) {
                raise(py.PyExc_ValueError(), "names: unknown type '{s}': expected bool, void, nil, int or str", .{pair[0]});
                return null;
            }
            if (!validType(&scratch, pair[1], "names")) return null;
        }

        var codes: [type_problem_kinds][]const u8 = .{
            "type-mismatch", "bad-operand", "arity",         "bad-argument", "not-callable",
            "no-field",      "bad-return",  "bad-condition", "unknown-type", "not-indexable",
        };
        var ignore: [type_problem_kinds]bool = @splat(false);
        const kind_names = comptime blk: {
            var names: [type_problem_kinds][]const u8 = undefined;
            for (@typeInfo(types_mod.ProblemKind).@"enum".fields, 0..) |f, i| names[i] = f.name;
            break :blk names;
        };
        for (textPairs(state, args, "codes") orelse return null) |pair| {
            const at = for (kind_names, 0..) |name, i| {
                if (std.mem.eql(u8, name, pair[0])) break i;
            } else {
                raise(py.PyExc_ValueError(), "codes: unknown kind '{s}'", .{pair[0]});
                return null;
            };
            codes[at] = pair[1];
        }
        if (py.c.PyDict_GetItemString(args, "ignore")) |obj| {
            for (strings(arena, obj, "ignore", false) orelse return null) |name| {
                const at = for (kind_names, 0..) |kind_name, i| {
                    if (std.mem.eql(u8, kind_name, name)) break i;
                } else {
                    raise(py.PyExc_ValueError(), "ignore: unknown kind '{s}'", .{name});
                    return null;
                };
                ignore[at] = true;
            }
        }

        const severity = textArg(state, args, "severity", "error") orelse return null;
        if (!std.mem.eql(u8, severity, "error") and !std.mem.eql(u8, severity, "warning") and !std.mem.eql(u8, severity, "note")) {
            raise(py.PyExc_ValueError(), "severity must be 'error', 'warning' or 'note'", .{});
            return null;
        }
        const basic: []const []const u8 = if (py.c.PyDict_GetItemString(args, "basic")) |b| strings(arena, b, "basic", false) orelse return null else &.{};

        tr.* = .{
            .namespace = textArg(state, args, "namespace", "") orelse return null,
            .literals = literals.items,
            .containers = containers.items,
            .type_names = compileSelectors(state, py.c.PyDict_GetItemString(args, "type_names"), "type_names") orelse return null,
            .type_args = compileSelectors(state, py.c.PyDict_GetItemString(args, "type_args"), "type_args") orelse return null,
            .optionals = compileSelectors(state, py.c.PyDict_GetItemString(args, "optional"), "optional") orelse return null,
            .variables = compileSelectors(state, py.c.PyDict_GetItemString(args, "variables"), "variables") orelse return null,
            .functions = compileSelectors(state, py.c.PyDict_GetItemString(args, "functions"), "functions") orelse return null,
            .structs = compileSelectors(state, py.c.PyDict_GetItemString(args, "structs"), "structs") orelse return null,
            .binaries = compileSelectors(state, py.c.PyDict_GetItemString(args, "binary"), "binary") orelse return null,
            .unaries = compileSelectors(state, py.c.PyDict_GetItemString(args, "unary"), "unary") orelse return null,
            .calls = compileSelectors(state, py.c.PyDict_GetItemString(args, "calls"), "calls") orelse return null,
            .indexes = compileSelectors(state, py.c.PyDict_GetItemString(args, "index"), "index") orelse return null,
            .assigns = compileSelectors(state, py.c.PyDict_GetItemString(args, "assigns"), "assigns") orelse return null,
            .returns = compileSelectors(state, py.c.PyDict_GetItemString(args, "returns"), "returns") orelse return null,
            .conditions = compileSelectors(state, py.c.PyDict_GetItemString(args, "conditions"), "conditions") orelse return null,
            .operators = operators.items,
            .basic = basic,
            .coerce = coerce,
            .builtins = builtins,
            .labels = labels,
            .names = type_names,
            .severity = severity,
            .codes = codes,
            .ignore = ignore,
        };
        return tr;
    }

    const flow_keys = [flow_problem_kinds][:0]const u8{ "unreachable", "missing_return", "unassigned", "maybe_unassigned" };

    fn compileFlow(state: *State, args: *PyObject) ?*const FlowRule {
        const arena = state.arena.allocator();
        const fr = arena.create(FlowRule) catch {
            _ = py.c.PyErr_NoMemory();
            return null;
        };

        // Which label each child is read through: its role's name, unless overridden
        var labels = flow_mod.Labels{};
        const overrides = textPairs(state, args, "labels") orelse return null;
        inline for (@typeInfo(flow_mod.Labels).@"struct".fields) |field| {
            var label: []const u8 = field.name;
            for (overrides) |pair| {
                if (std.mem.eql(u8, pair[0], field.name)) label = pair[1];
            }
            for (state.names.fields, 1..) |f, id| {
                if (std.mem.eql(u8, f, label)) @field(labels, field.name) = @intCast(id);
            }
        }
        for (overrides) |pair| {
            var known = false;
            inline for (@typeInfo(flow_mod.Labels).@"struct".fields) |field| {
                if (std.mem.eql(u8, pair[0], field.name)) known = true;
            }
            if (!known) {
                raise(py.PyExc_ValueError(), "labels: unknown role '{s}': expected name, value or target", .{pair[0]});
                return null;
            }
        }

        var messages = [flow_problem_kinds][]const u8{
            "unreachable code",
            "'{text}' may end without returning a value",
            "'{text}' is used before it has a value",
            "'{text}' may be used before it has a value",
        };
        var codes = [flow_problem_kinds][]const u8{ "unreachable", "missing-return", "unassigned", "unassigned" };
        inline for (.{ .{ "messages", &messages }, .{ "codes", &codes } }) |option| {
            for (textPairs(state, args, option[0]) orelse return null) |pair| {
                const at = for (flow_keys, 0..) |k, i| {
                    if (std.mem.eql(u8, k, pair[0])) break i;
                } else {
                    raise(py.PyExc_ValueError(), "{s}: unknown kind '{s}': the keys are 'unreachable', 'missing_return', 'unassigned' and 'maybe_unassigned'", .{ option[0], pair[0] });
                    return null;
                };
                option[1][at] = pair[1];
            }
        }
        const unassigned = levelArg(args, "on_unassigned", .err) orelse return null;

        fr.* = .{
            .namespace = textArg(state, args, "namespace", "") orelse return null,
            .sequences = compileSelectors(state, py.c.PyDict_GetItemString(args, "sequences"), "sequences") orelse return null,
            .functions = compileSelectors(state, py.c.PyDict_GetItemString(args, "functions"), "functions") orelse return null,
            .branches = compileSelectors(state, py.c.PyDict_GetItemString(args, "branches"), "branches") orelse return null,
            .arms = compileSelectors(state, py.c.PyDict_GetItemString(args, "arms"), "arms") orelse return null,
            .otherwise = compileSelectors(state, py.c.PyDict_GetItemString(args, "otherwise"), "otherwise") orelse return null,
            .loops = compileSelectors(state, py.c.PyDict_GetItemString(args, "loops"), "loops") orelse return null,
            .forever = compileSelectors(state, py.c.PyDict_GetItemString(args, "forever"), "forever") orelse return null,
            .at_least_once = compileSelectors(state, py.c.PyDict_GetItemString(args, "at_least_once"), "at_least_once") orelse return null,
            .exits = compileSelectors(state, py.c.PyDict_GetItemString(args, "exits"), "exits") orelse return null,
            .breaks = compileSelectors(state, py.c.PyDict_GetItemString(args, "breaks"), "breaks") orelse return null,
            .continues = compileSelectors(state, py.c.PyDict_GetItemString(args, "continues"), "continues") orelse return null,
            .must_return = compileSelectors(state, py.c.PyDict_GetItemString(args, "must_return"), "must_return") orelse return null,
            .variables = compileSelectors(state, py.c.PyDict_GetItemString(args, "variables"), "variables") orelse return null,
            .assigns = compileSelectors(state, py.c.PyDict_GetItemString(args, "assigns"), "assigns") orelse return null,
            .labels = labels,
            .levels = .{
                levelArg(args, "on_unreachable", .warning) orelse return null,
                levelArg(args, "on_missing_return", .err) orelse return null,
                unassigned,
                unassigned,
            },
            .messages = messages,
            .codes = codes,
        };
        if (fr.sequences.len == 0) {
            raise(py.PyExc_ValueError(), "flow() needs `sequences`: the nodes whose children are statements run in order", .{});
            return null;
        }
        if (fr.must_return.len != 0 and fr.functions.len == 0) {
            raise(py.PyExc_ValueError(), "flow(must_return=...) needs `functions`", .{});
            return null;
        }
        return fr;
    }

    fn compileRule(state: *State, kind: Kind, args: *PyObject) ?CompiledRule {
        if (kind == .flow) {
            const compiled_flow = compileFlow(state, args) orelse return null;
            return .{ .kind = kind, .message = "", .code = "", .severity = "error", .flow = compiled_flow };
        }
        if (kind == .scopes) {
            const scope = compileScopes(state, args) orelse return null;
            return .{ .kind = kind, .message = "", .code = "", .severity = "error", .scope = scope };
        }
        if (kind == .types) {
            const compiled_types = compileTypes(state, args) orelse return null;
            return .{ .kind = kind, .message = "", .code = "", .severity = "error", .types = compiled_types };
        }
        const sel_obj = py.c.PyDict_GetItemString(args, "selector") orelse {
            raise(py.PyExc_ValueError(), "rule has no selector", .{});
            return null;
        };
        var compiled = CompiledRule{
            .kind = kind,
            .selectors = compileSelectors(state, sel_obj, "selector") orelse return null,
            .message = textArg(state, args, "message", switch (kind) {
                .inside, .forbid => "{rule} is not allowed here",
                .unique => "duplicate '{text}'",
                .require => "{rule} is incomplete",
                .count => "wrong number of items ({count})",
                .scopes, .custom, .types, .flow => "",
            }) orelse return null,
            .code = textArg(state, args, "code", @tagName(kind)) orelse return null,
            .severity = textArg(state, args, "severity", "error") orelse return null,
        };
        if (!std.mem.eql(u8, compiled.severity, "error") and !std.mem.eql(u8, compiled.severity, "warning") and !std.mem.eql(u8, compiled.severity, "note")) {
            raise(py.PyExc_ValueError(), "severity must be 'error', 'warning' or 'note'", .{});
            return null;
        }
        if (compiled.selectors.len == 0) {
            raise(py.PyExc_ValueError(), "selector is empty", .{});
            return null;
        }
        switch (kind) {
            .inside => {
                compiled.within = compileSelectors(state, py.c.PyDict_GetItemString(args, "within"), "within") orelse return null;
                compiled.stop_at = compileSelectors(state, py.c.PyDict_GetItemString(args, "stop_at"), "stop_at") orelse return null;
                if (compiled.within.len == 0) {
                    raise(py.PyExc_ValueError(), "inside() needs at least one `within` selector", .{});
                    return null;
                }
            },
            .require => for (compiled.selectors) |sel| {
                if (sel.compounds.len >= 2) continue;
                raise(py.PyExc_ValueError(), "require('{s}'): the selector needs a parent and the required part, as in 'funcdef > block'", .{sel.source});
                return null;
            },
            .unique => compiled.within = compileSelectors(state, py.c.PyDict_GetItemString(args, "within"), "within") orelse return null,
            .count => {
                compiled.within = compileSelectors(state, py.c.PyDict_GetItemString(args, "within"), "within") orelse return null;
                var failed = false;
                const exactly = intArg(args, "exactly", &failed);
                const lo = intArg(args, "min", &failed);
                const hi = intArg(args, "max", &failed);
                if (failed) return null;
                if (exactly != null and (lo != null or hi != null)) {
                    raise(py.PyExc_ValueError(), "count(): give `exactly`, or `min` and/or `max`, not both", .{});
                    return null;
                }
                if (exactly == null and lo == null and hi == null) {
                    raise(py.PyExc_ValueError(), "count() needs `exactly`, `min` or `max`", .{});
                    return null;
                }
                compiled.min = exactly orelse lo orelse 0;
                compiled.max = exactly orelse hi orelse std.math.maxInt(u32);
            },
            .custom => {
                const function = py.c.PyDict_GetItemString(args, "function") orelse {
                    raise(py.PyExc_ValueError(), "custom rule has no function", .{});
                    return null;
                };
                if (py.c.PyCallable_Check(function) == 0) {
                    raise(py.PyExc_TypeError(), "a custom rule's function must be callable: function(node, ctx)", .{});
                    return null;
                }
                py.Py_IncRef(function);
                compiled.callback = function;
            },
            .forbid, .scopes, .types, .flow => {},
        }
        return compiled;
    }

    fn destroyState(state: *State) void {
        for (state.rules.items) |r| {
            if (r.callback) |f| py.Py_DecRef(f);
            if (r.scope) |sr| {
                if (sr.on_unresolved) |f| py.Py_DecRef(f);
            }
        }
        state.arena.deinit();
        allocator.destroy(state);
    }

    /// Rules(parser, rules): compile rules against a zgram parser's grammar.
    pub fn __new__(args: pyoz.Args(struct { parser: *PyObject, rules: ?*PyObject = null })) ?Rules {
        const parser = args.value.parser;
        const state = allocator.create(State) catch {
            _ = py.c.PyErr_NoMemory();
            return null;
        };
        state.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .names = undefined };
        var ok = false;
        defer if (!ok) destroyState(state);
        const arena = state.arena.allocator();

        state.names = .{
            .rules = nameList(arena, parser, "rules") orelse return null,
            .fields = nameList(arena, parser, "fields") orelse return null,
            .actions = nameList(arena, parser, "actions") orelse return null,
        };
        if (state.names.actions.len != state.names.rules.len) {
            raise(py.PyExc_TypeError(), "Rules() needs a zgram parser (actions() and rules() disagree)", .{});
            return null;
        }

        if (args.value.rules) |rules| {
            if (rules != py.Py_None()) {
                const n = py.c.PySequence_Size(rules);
                if (n < 0 or py.PyUnicode_Check(rules)) {
                    py.c.PyErr_Clear();
                    raise(py.PyExc_TypeError(), "rules must be a sequence of rules", .{});
                    return null;
                }
                for (0..@intCast(n)) |i| {
                    const item = py.c.PySequence_GetItem(rules, @intCast(i)) orelse return null;
                    defer py.Py_DecRef(item);
                    const spec = Module.fromPy(*const Rule, item) catch {
                        py.c.PyErr_Clear();
                        raise(py.PyExc_TypeError(), "rules[{d}] is not a rule (use inside(), unique(), forbid(), require(), count(), scopes(), types(), flow() or custom())", .{i});
                        return null;
                    };
                    const compiled = compileRule(state, @enumFromInt(spec._kind), spec._args orelse return null) orelse return null;
                    state.rules.append(arena, compiled) catch {
                        if (compiled.callback) |f| py.Py_DecRef(f);
                        _ = py.c.PyErr_NoMemory();
                        return null;
                    };
                }
            }
        }

        // A types() rule types the names of a scopes() rule, and its basic
        // types are names that rule must know: `int` in `x: int` is a use
        for (state.rules.items) |r| {
            const tr = r.types orelse continue;
            var target: ?*ScopeRule = null;
            for (state.rules.items) |other| {
                const sr = other.scope orelse continue;
                if (tr.namespace.len == 0 or std.mem.eql(u8, sr.namespace, tr.namespace)) {
                    target = @constCast(sr);
                    break;
                }
            }
            const sr = target orelse {
                if (tr.namespace.len == 0) raise(py.PyExc_ValueError(), "types() needs a scopes() rule in the same Rules: it types the names that rule resolves", .{}) else raise(py.PyExc_ValueError(), "types(namespace='{s}'): no scopes() rule has that namespace", .{tr.namespace});
                return null;
            };
            const extended = arena.alloc([]const u8, sr.builtins.len + tr.basic.len) catch {
                _ = py.c.PyErr_NoMemory();
                return null;
            };
            @memcpy(extended[0..sr.builtins.len], sr.builtins);
            @memcpy(extended[sr.builtins.len..], tr.basic);
            sr.builtins = extended;
        }

        // A flow() rule that follows variables reads them from a scopes() rule
        for (state.rules.items) |r| {
            const fr = r.flow orelse continue;
            if (fr.variables.len == 0 and fr.assigns.len == 0) continue;
            const found = for (state.rules.items) |other| {
                const sr = other.scope orelse continue;
                if (fr.namespace.len == 0 or std.mem.eql(u8, sr.namespace, fr.namespace)) break true;
            } else false;
            if (found) continue;
            if (fr.namespace.len == 0) raise(py.PyExc_ValueError(), "flow(variables=..., assigns=...) needs a scopes() rule in the same Rules: it follows the names that rule resolves", .{}) else raise(py.PyExc_ValueError(), "flow(namespace='{s}'): no scopes() rule has that namespace", .{fr.namespace});
            return null;
        }

        ok = true;
        py.Py_IncRef(parser);
        return .{ ._state = state, ._parser = parser };
    }

    pub fn __del__(self: *Rules) void {
        if (self._state) |state| destroyState(state);
        self._state = null;
        if (self._parser) |p| py.Py_DecRef(p);
        self._parser = null;
    }

    pub fn __len__(self: *const Rules) i64 {
        return if (self._state) |s| @intCast(s.rules.items.len) else 0;
    }

    pub fn __repr__(self: *const Rules, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "Rules({d} rules)", .{self.__len__()}) catch buf[0..0];
    }

    /// Add a custom rule: `function(node, ctx)` is called for every node
    /// matching `selector`. Returns the function, so that
    /// `rules.rule(selector)` works as a decorator.
    pub fn add(self: *Rules, args: pyoz.Args(struct { selector: *PyObject, function: *PyObject, code: ?*PyObject = null })) pyoz.Signature(?*PyObject, "Callable") {
        const state = self._state orelse {
            raise(py.PyExc_RuntimeError(), "Rules is not initialized", .{});
            return .{ .value = null };
        };
        const a = args.value;
        const dict = py.c.PyDict_New() orelse return .{ .value = null };
        defer py.Py_DecRef(dict);
        if (py.c.PyDict_SetItemString(dict, "selector", a.selector) != 0 or py.c.PyDict_SetItemString(dict, "function", a.function) != 0) return .{ .value = null };
        if (a.code) |code| {
            if (code != py.Py_None() and py.c.PyDict_SetItemString(dict, "code", code) != 0) return .{ .value = null };
        }
        const compiled = compileRule(state, .custom, dict) orelse return .{ .value = null };
        state.rules.append(state.arena.allocator(), compiled) catch {
            if (compiled.callback) |f| py.Py_DecRef(f);
            return .{ .value = oomObject() };
        };
        py.Py_IncRef(a.function);
        return .{ .value = a.function };
    }

    /// Decorator form of add(): `@rules.rule("Call")`.
    pub fn rule(self: *Rules, args: pyoz.Args(struct { selector: *PyObject, code: ?*PyObject = null })) pyoz.Signature(?*PyObject, "Callable") {
        const functools = py.c.PyImport_ImportModule("functools") orelse return .{ .value = null };
        defer py.Py_DecRef(functools);
        const bound = py.c.PyObject_GetAttrString(Module.selfObject(Rules, self), "add") orelse return .{ .value = null };
        defer py.Py_DecRef(bound);
        // partial(self.add, selector, code=code): calling it with the function registers it
        const call_args = py.c.Py_BuildValue("(OO)", bound, args.value.selector) orelse return .{ .value = null };
        defer py.Py_DecRef(call_args);
        const kwargs = py.c.PyDict_New() orelse return .{ .value = null };
        defer py.Py_DecRef(kwargs);
        if (args.value.code) |code| {
            if (py.c.PyDict_SetItemString(kwargs, "code", code) != 0) return .{ .value = null };
        }
        const partial = py.c.PyObject_GetAttrString(functools, "partial") orelse return .{ .value = null };
        defer py.Py_DecRef(partial);
        return .{ .value = py.c.PyObject_Call(partial, call_args, kwargs) };
    }

    // ── Checking ──

    /// What a message template can mention
    const Values = struct {
        /// {text}: the flagged node's text; {rule}: its rule name
        text: []const u8 = "",
        rule: []const u8 = "",
        /// {field}: its label ("" without one); {parent}: its parent's rule name
        field: []const u8 = "",
        parent: []const u8 = "",
        /// {owner}: for a missing member, the name that lacks it
        owner: []const u8 = "",
        /// {count}, and the {min} / {max} it was checked against
        count: u32 = 0,
        min: u32 = 0,
        max: u32 = std.math.maxInt(u32),
    };

    /// Expand the placeholders of a message template; anything else in
    /// braces is left as written.
    fn format(arena: std.mem.Allocator, template: []const u8, v: Values) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        outer: while (i < template.len) {
            if (template[i] == '{') {
                const rest = template[i..];
                inline for (.{ "text", "rule", "field", "parent", "owner" }) |name| {
                    if (std.mem.startsWith(u8, rest, "{" ++ name ++ "}")) {
                        try out.appendSlice(arena, @field(v, name));
                        i += name.len + 2;
                        continue :outer;
                    }
                }
                inline for (.{ "count", "min", "max" }) |name| {
                    if (std.mem.startsWith(u8, rest, "{" ++ name ++ "}")) {
                        var buf: [16]u8 = undefined;
                        const n: u32 = @field(v, name);
                        try out.appendSlice(arena, if (n == std.math.maxInt(u32)) "any number" else std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
                        i += name.len + 2;
                        continue :outer;
                    }
                }
            }
            try out.append(arena, template[i]);
            i += 1;
        }
        return out.items;
    }

    /// The names found by one scopes() rule
    const ScopeResult = struct {
        namespace: []const u8,
        result: scopes_mod.Result,
    };

    /// The files of a project, for resolving imports between them
    const Link = struct {
        runs: []const *Run,
        keys: []const *PyObject,
        /// Key text (of the keys that are str) -> file index
        by_text: std.StringHashMapUnmanaged(u32) = .empty,
        /// With a resolver: key -> file index, as a dict
        by_key: ?*PyObject = null,
        /// resolve(module_text, importing_key) -> key or None. Without one,
        /// a module's text (minus quotes) is the key of its file.
        resolver: ?*PyObject,

        /// The index of the file that `module`, written in file `from`,
        /// refers to; null if there is none.
        fn resolve(self: *const Link, from: usize, module: []const u8) error{PythonError}!?u32 {
            if (self.resolver) |function| {
                const text = py.PyUnicode_FromStringAndSize(module.ptr, @intCast(module.len)) orelse return error.PythonError;
                defer py.Py_DecRef(text);
                const key = py.c.PyObject_CallFunctionObjArgs(function, text, self.keys[from], @as(?*PyObject, null)) orelse return error.PythonError;
                defer py.Py_DecRef(key);
                if (key == py.Py_None()) return null;
                const found = py.c.PyDict_GetItemWithError(self.by_key.?, key) orelse {
                    // Not a key of the project (one that can't be hashed is none of them)
                    py.c.PyErr_Clear();
                    return null;
                };
                return @intCast(py.c.PyLong_AsUnsignedLong(found));
            }
            var name = module;
            if (name.len >= 2 and (name[0] == '"' or name[0] == '\'') and name[name.len - 1] == name[0]) name = name[1 .. name.len - 1];
            if (name.len == 0) return null;
            return self.by_text.get(name);
        }
    };

    const Run = struct {
        arena: std.mem.Allocator,
        state: *const State,
        tree: *const Tree,
        findings: std.ArrayList(Finding) = .empty,
        scope_results: std.ArrayList(ScopeResult) = .empty,
        /// Undefined names whose scopes() rule has an on_unresolved function
        /// to ask first (from Python, once the symbols are available)
        unresolved: std.ArrayList(Unresolved) = .empty,
        scope_inputs: std.ArrayList(ScopeInput) = .empty,
        /// Several files are being checked together: exports are needed
        in_project: bool = false,
        /// The broken text of a recovered tree; null for a tree without
        /// syntax errors
        broken: ?*const Broken = null,

        /// Nodes grouped by grammar rule: rule r's nodes, in source order,
        /// are by_rule[rule_start[r]..rule_start[r + 1]]. A rule only looks
        /// at the nodes its selector can end on, not at the whole tree.
        rule_start: []const u32 = &.{},
        by_rule: []const u32 = &.{},
        /// The same by label: field f's nodes are by_field[field_start[f]..field_start[f + 1]]
        field_start: []const u32 = &.{},
        by_field: []const u32 = &.{},
        /// 0, 1, 2, ...: the candidates of a selector part without a name
        every_node: ?[]const u32 = null,

        const Unresolved = struct { rule: *const ScopeRule, problem: scopes_mod.Problem };

        /// One imported name: what the other file calls it, and the node
        /// that names it here
        const ImportName = struct {
            imported: []const u8,
            /// The node holding the imported name (where a missing one is reported)
            node: u32,
            local: u32,
        };

        const Import = struct {
            /// The node naming the module
            module: u32,
            names: []const ImportName,
            /// The node defining the module's local name; NONE when the
            /// import brings in names instead
            local: u32,
            wildcard: bool,
            /// The file the module is, once resolved (NONE: no such file)
            target: u32 = NONE,
        };

        /// What a scopes() rule matched in this file, kept between the two
        /// passes of a check (every file's exports, then the resolution)
        const ScopeInput = struct {
            rule: *const ScopeRule,
            scope_nodes: []const u32,
            outside: []const u32 = &.{},
            defs: []const scopes_mod.Definition,
            uses: []const u32,
            members: []const scopes_mod.Member,
            imports: []Import,
            /// Top-level names this file offers to the others -> defining node
            exports: std.StringHashMapUnmanaged(u32) = .empty,
        };

        fn buildIndex(self: *Run) !void {
            const nodes = self.tree.nodes;
            const n_rules = self.state.names.rules.len;
            const start = try self.arena.alloc(u32, n_rules + 1);
            @memset(start, 0);
            for (nodes) |n| {
                if (n.ruleId() < n_rules) start[n.ruleId() + 1] += 1;
            }
            for (1..start.len) |r| start[r] += start[r - 1];
            const by_rule = try self.arena.alloc(u32, nodes.len);
            const next = try self.arena.dupe(u32, start[0..n_rules]);
            for (nodes, 0..) |n, i| {
                if (n.ruleId() >= n_rules) continue;
                by_rule[next[n.ruleId()]] = @intCast(i);
                next[n.ruleId()] += 1;
            }
            self.rule_start = start;
            self.by_rule = by_rule;

            const fstart = try self.arena.alloc(u32, 257);
            @memset(fstart, 0);
            for (nodes) |n| fstart[@as(usize, n.fieldId()) + 1] += 1;
            for (1..fstart.len) |f| fstart[f] += fstart[f - 1];
            const by_field = try self.arena.alloc(u32, nodes.len);
            const fnext = try self.arena.dupe(u32, fstart[0..256]);
            for (nodes, 0..) |n, i| {
                by_field[fnext[n.fieldId()]] = @intCast(i);
                fnext[n.fieldId()] += 1;
            }
            self.field_start = fstart;
            self.by_field = by_field;
        }

        /// The nodes a selector part can match, in source order.
        fn candidates(self: *Run, part: selector.Compound) ![]const u32 {
            const labelled: ?[]const u32 = if (part.field != 0) self.by_field[self.field_start[part.field]..self.field_start[@as(usize, part.field) + 1]] else null;
            const accepted = part.rules orelse {
                if (labelled) |l| return l;
                if (self.every_node == null) {
                    const all = try self.arena.alloc(u32, self.tree.nodes.len);
                    for (all, 0..) |*slot, i| slot.* = @intCast(i);
                    self.every_node = all;
                }
                return self.every_node.?;
            };
            var only: ?usize = null;
            var several = false;
            var total: usize = 0;
            for (accepted, 0..) |yes, r| {
                if (!yes) continue;
                several = only != null;
                only = r;
                total += self.rule_start[r + 1] - self.rule_start[r];
            }
            const one = only orelse return &.{};
            // Both a name and a label: start from whichever is rarer
            if (labelled) |l| {
                if (l.len < total) return l;
            }
            if (!several) return self.by_rule[self.rule_start[one]..self.rule_start[one + 1]];
            // A class name covering several rules: merge their nodes
            const merged = try self.arena.alloc(u32, total);
            var at: usize = 0;
            for (accepted, 0..) |yes, r| {
                if (!yes) continue;
                const part_nodes = self.by_rule[self.rule_start[r]..self.rule_start[r + 1]];
                @memcpy(merged[at..][0..part_nodes.len], part_nodes);
                at += part_nodes.len;
            }
            std.sort.pdq(u32, merged, {}, std.sort.asc(u32));
            return merged;
        }

        /// Add a finding; null if it is about broken text (whose syntax
        /// error says it), which is left out.
        fn add(self: *Run, finding: Finding) !?*Finding {
            if (self.broken) |b| {
                if (b.touches(self.tree, finding.start, finding.end)) return null;
            }
            var f = finding;
            f.order = @intCast(self.findings.items.len);
            try self.findings.append(self.arena, f);
            return &self.findings.items[self.findings.items.len - 1];
        }

        fn ruleName(self: *const Run, node: u32) []const u8 {
            const id = self.tree.nodes[node].ruleId();
            return if (id < self.state.names.rules.len) self.state.names.rules[id] else "?";
        }

        fn values(self: *const Run, node: u32) Values {
            const flat = self.tree.nodes[node];
            const fields = self.state.names.fields;
            const parent = self.tree.parents[node];
            return .{
                .text = self.tree.text(node),
                .rule = self.ruleName(node),
                .field = if (flat.fieldId() != 0 and flat.fieldId() <= fields.len) fields[flat.fieldId() - 1] else "",
                .parent = if (parent == NONE) "" else self.ruleName(parent),
            };
        }

        fn report(self: *Run, rule_idx: usize, node: u32, n: u32) !?*Finding {
            const r = self.state.rules.items[rule_idx];
            const flat = self.tree.nodes[node];
            var v = self.values(node);
            v.count = n;
            v.min = r.min;
            v.max = r.max;
            return self.add(.{
                .start = flat.text_start,
                .end = flat.text_end,
                .severity = r.severity,
                .code = r.code,
                .message = try format(self.arena, r.message, v),
            });
        }

        /// The nearest ancestor of `node` matching one of `selectors`, or NONE.
        fn groupOf(self: *const Run, selectors: []const Selector, node: u32) u32 {
            var p = self.tree.parents[node];
            while (p != NONE and !self.anyMatches(selectors, p)) p = self.tree.parents[p];
            return p;
        }

        fn anyMatches(self: *const Run, selectors: []const Selector, node: u32) bool {
            for (selectors) |*s| {
                if (s.matches(self.tree, node, null)) return true;
            }
            return false;
        }

        /// Every node matching any of the selectors, in source order, once.
        fn matchAll(self: *Run, selectors: []const Selector) ![]const u32 {
            if (selectors.len == 0) return &.{};
            // Each selector's matches are in source order: merge them
            var merged = try self.matchOne(&selectors[0]);
            for (selectors[1..]) |*s| {
                const more = try self.matchOne(s);
                if (more.len == 0) continue;
                if (merged.len == 0) {
                    merged = more;
                    continue;
                }
                const out = try self.arena.alloc(u32, merged.len + more.len);
                var i: usize = 0;
                var j: usize = 0;
                var n: usize = 0;
                while (i < merged.len or j < more.len) {
                    const take_left = j == more.len or (i < merged.len and merged[i] <= more[j]);
                    const node = if (take_left) merged[i] else more[j];
                    if (take_left) i += 1 else j += 1;
                    // A node both select is listed once
                    if (n != 0 and out[n - 1] == node) continue;
                    out[n] = node;
                    n += 1;
                }
                merged = out[0..n];
            }
            // Read-only: it may be a slice of the node index itself
            return merged;
        }

        /// The nodes one selector matches, in source order.
        fn matchOne(self: *Run, s: *const Selector) ![]const u32 {
            const last = s.compounds[s.compounds.len - 1];
            // `a > b` where b names no rule or label (`x > :not(y)`): every
            // node would be a candidate; the children of the a's are enough
            if (last.rules == null and last.field == 0 and last.relation == .child) {
                const parent_part = s.compounds[s.compounds.len - 2];
                if (parent_part.rules != null or parent_part.field != 0) return self.matchChildren(s, parent_part);
            }
            const found = try self.candidates(last);
            // Just a name or a label: its candidates are the answer
            if (s.compounds.len == 1 and isPlain(last) and (last.rules == null or last.field == 0)) return found;
            const out = try self.arena.alloc(u32, found.len);
            var n: usize = 0;
            // `a > b` with both parts a plain name or label (`let_stmt > .name`),
            // the commonest shape by far: two table lookups per candidate
            if (s.compounds.len == 2 and last.relation == .child and isPlain(last) and isPlain(s.compounds[0])) {
                const t = self.tree;
                const parent_part = s.compounds[0];
                for (found) |node| {
                    if (!plainMatches(t, last, node)) continue;
                    const parent = t.parents[node];
                    if (parent == NONE or !plainMatches(t, parent_part, parent)) continue;
                    out[n] = node;
                    n += 1;
                }
                return out[0..n];
            }
            for (found) |node| {
                if (!s.matches(self.tree, node, null)) continue;
                out[n] = node;
                n += 1;
            }
            return out[0..n];
        }

        /// The children of the parent part's candidates that match `s`, in source order.
        fn matchChildren(self: *Run, s: *const Selector, parent_part: selector.Compound) ![]const u32 {
            const t = self.tree;
            var out: std.ArrayList(u32) = .empty;
            var in_order = true;
            for (try self.candidates(parent_part)) |parent| {
                if (!plainMatches(t, parent_part, parent)) continue;
                const stop = t.end(parent);
                var child = parent + 1;
                while (child < stop) : (child = t.end(child)) {
                    if (!s.matches(t, child, null)) continue;
                    // A parent inside another one's child comes later in the list
                    if (out.items.len != 0 and out.items[out.items.len - 1] >= child) in_order = false;
                    try out.append(self.arena, child);
                }
            }
            if (!in_order) std.sort.pdq(u32, out.items, {}, std.sort.asc(u32));
            return out.items;
        }

        /// A part that is only a name and/or a label
        fn isPlain(c: selector.Compound) bool {
            return c.attrs.len == 0 and c.nots.len == 0 and c.has.len == 0 and c.nth == 0 and !c.last;
        }

        fn plainMatches(t: *const Tree, c: selector.Compound, node: u32) bool {
            const flat = t.nodes[node];
            if (c.field != 0 and flat.fieldId() != c.field) return false;
            const rules = c.rules orelse return true;
            const id = flat.ruleId();
            return id < rules.len and rules[id];
        }

        /// What a types() rule matched in this file, for the checker. `r`
        /// is the scopes() result whose names it types.
        fn typeInputs(self: *Run, tr: *const TypeRule, r: usize) !types_mod.Inputs {
            const literals = try self.arena.alloc(types_mod.Literal, tr.literals.len);
            for (literals, tr.literals) |*slot, lit| slot.* = .{ .nodes = try self.matchAll(lit.selectors), .type = lit.type };
            const containers = try self.arena.alloc(types_mod.Container, tr.containers.len);
            for (containers, tr.containers) |*slot, c| slot.* = .{ .nodes = try self.matchAll(c.selectors), .name = c.type };
            return .{
                .labels = tr.labels,
                .names = tr.names,
                .literals = literals,
                .containers = containers,
                .type_names = try self.matchAll(tr.type_names),
                .type_args = try self.matchAll(tr.type_args),
                .optionals = try self.matchAll(tr.optionals),
                .variables = try self.matchAll(tr.variables),
                .functions = try self.matchAll(tr.functions),
                .structs = try self.matchAll(tr.structs),
                .binaries = try self.matchAll(tr.binaries),
                .unaries = try self.matchAll(tr.unaries),
                .calls = try self.matchAll(tr.calls),
                .indexes = try self.matchAll(tr.indexes),
                .members = self.scope_inputs.items[r].members,
                .uses = self.scope_inputs.items[r].uses,
                .assigns = try self.matchAll(tr.assigns),
                .returns = try self.matchAll(tr.returns),
                .conditions = try self.matchAll(tr.conditions),
                .operators = tr.operators,
                .basic = tr.basic,
                .coerce = tr.coerce,
                .builtins = tr.builtins,
            };
        }

        /// Run a flow() rule over this file and report what it finds.
        fn runFlow(self: *Run, fr: *const FlowRule) !void {
            var inputs = flow_mod.Inputs{
                .labels = fr.labels,
                .sequences = try self.matchAll(fr.sequences),
                .functions = try self.matchAll(fr.functions),
                .branches = try self.matchAll(fr.branches),
                .arms = try self.matchAll(fr.arms),
                .otherwise = try self.matchAll(fr.otherwise),
                .loops = try self.matchAll(fr.loops),
                .forever = try self.matchAll(fr.forever),
                .at_least_once = try self.matchAll(fr.at_least_once),
                .exits = try self.matchAll(fr.exits),
                .breaks = try self.matchAll(fr.breaks),
                .continues = try self.matchAll(fr.continues),
                .must_return = try self.matchAll(fr.must_return),
                .variables = try self.matchAll(fr.variables),
                .assigns = try self.matchAll(fr.assigns),
            };
            // The scopes() rule whose names it follows
            for (self.scope_results.items, 0..) |*result, r| {
                if (fr.namespace.len != 0 and !std.mem.eql(u8, result.namespace, fr.namespace)) continue;
                inputs.names = &result.result;
                inputs.uses = self.scope_inputs.items[r].uses;
                inputs.definitions = self.scope_inputs.items[r].defs;
                inputs.members = self.scope_inputs.items[r].members;
                break;
            }
            var analysis = flow_mod.Analysis{ .arena = self.arena, .tree = self.tree, .in = inputs };
            try analysis.run();
            // A function (or the top level) with broken text of its own has
            // paths nobody can follow: what didn't parse may have returned,
            // assigned or ended a block
            var is_function: []bool = &.{};
            var broken_units: std.ArrayList(u32) = .empty;
            if (self.broken) |b| {
                is_function = try self.arena.alloc(bool, self.tree.nodes.len);
                @memset(is_function, false);
                for (inputs.functions) |node| is_function[node] = true;
                for (b.nodes) |node| try broken_units.append(self.arena, self.unitOf(is_function, node));
                for (b.offsets) |offset| try broken_units.append(self.arena, self.unitOf(is_function, self.nodeAt(offset)));
            }
            for (analysis.problems.items) |p| {
                const k = @intFromEnum(p.kind);
                if (fr.levels[k] == .ignore) continue;
                if (broken_units.items.len != 0 and std.mem.indexOfScalar(u32, broken_units.items, self.unitOf(is_function, p.node)) != null) continue;
                const flat = self.tree.nodes[p.node];
                _ = try self.add(.{
                    .start = flat.text_start,
                    .end = flat.text_end,
                    .severity = if (fr.levels[k] == .err) "error" else "warning",
                    .code = fr.codes[k],
                    .message = try format(self.arena, fr.messages[k], self.values(p.node)),
                });
            }
        }

        /// The function `node` is in (itself, if it is one), or the root.
        fn unitOf(self: *const Run, is_function: []const bool, node: u32) u32 {
            var n = node;
            while (n != NONE and n != 0) : (n = self.tree.parents[n]) {
                if (is_function[n]) return n;
            }
            return 0;
        }

        /// The innermost node whose text contains `offset`, or ends there
        /// (a missing `}` belongs to the block that ends where it's
        /// missing); the root if none.
        fn nodeAt(self: *const Run, offset: u32) u32 {
            const t = self.tree;
            if (t.nodes.len == 0) return 0;
            var node: u32 = 0;
            descend: while (true) {
                const stop = t.end(node);
                var child = node + 1;
                while (child < stop) : (child = t.end(child)) {
                    const c = t.nodes[child];
                    if (c.text_start <= offset and offset <= c.text_end) {
                        node = child;
                        continue :descend;
                    }
                }
                return node;
            }
        }

        /// The child of `node` labelled `field`, or NONE (field 0 never matches).
        fn childLabelled(self: *const Run, node: u32, field: u8) u32 {
            if (field == 0) return NONE;
            const t = self.tree;
            const stop = t.end(node);
            var child = node + 1;
            while (child < stop) : (child = t.end(child)) {
                if (t.nodes[child].fieldId() == field) return child;
            }
            return NONE;
        }

        /// First pass of a scopes() rule: match its selectors, find the
        /// imports, and (in a project) work out what the file exports.
        fn prepareScopes(self: *Run, sr: *const ScopeRule) !void {
            const t = self.tree;
            const scope_nodes = try self.matchAll(sr.scope);
            const inner = try self.matchAll(sr.define);
            const outer = try self.matchAll(sr.define_outer);
            const hoisted = try self.matchAll(sr.hoist);
            const after = try self.matchAll(sr.after);
            const uses = try self.matchAll(sr.use);

            // Every list is in source order: merge them in one pass
            var defs: std.ArrayList(scopes_mod.Definition) = .empty;
            try defs.ensureTotalCapacity(self.arena, inner.len + outer.len);
            {
                var i: usize = 0;
                var o: usize = 0;
                var h: usize = 0;
                var a: usize = 0;
                while (i < inner.len or o < outer.len) {
                    // Listed in both: the outer form wins
                    const take_outer = i == inner.len or (o < outer.len and outer[o] <= inner[i]);
                    const node = if (take_outer) outer[o] else inner[i];
                    if (take_outer) {
                        if (i < inner.len and inner[i] == node) i += 1;
                        o += 1;
                    } else i += 1;
                    while (h < hoisted.len and hoisted[h] < node) h += 1;
                    while (a < after.len and after[a] < node) a += 1;
                    const parent = t.parents[node];
                    const whole = parent != NONE and a < after.len and after[a] == node;
                    defs.appendAssumeCapacity(.{
                        .node = node,
                        .outer = take_outer,
                        .hoisted = h < hoisted.len and hoisted[h] == node,
                        .visible_from = t.nodes[if (whole) parent else node].text_end,
                    });
                }
            }

            // Imports define names too: the imported names (or their
            // aliases), or the module's name (or its alias)
            var imports: std.ArrayList(Import) = .empty;
            const wild = try self.matchAll(sr.import_all);
            const both = try self.arena.alloc(Selector, sr.imports.len + sr.import_all.len);
            @memcpy(both[0..sr.imports.len], sr.imports);
            @memcpy(both[sr.imports.len..], sr.import_all);
            const import_nodes = try self.matchAll(both);
            for (import_nodes) |node| {
                const module = self.childLabelled(node, sr.import_module);
                if (module == NONE) continue;
                var import = Import{
                    .module = module,
                    .names = &.{},
                    .local = NONE,
                    .wildcard = std.sort.binarySearch(u32, wild, node, orderU32) != null,
                };
                var names: std.ArrayList(ImportName) = .empty;
                if (!import.wildcard and sr.import_names != 0) {
                    const stop = t.end(node);
                    var child = node + 1;
                    while (child < stop) : (child = t.end(child)) {
                        if (t.nodes[child].fieldId() != sr.import_names) continue;
                        // `name as alias`: a node holding both, the alias labelled
                        const alias = self.childLabelled(child, sr.import_alias);
                        // The imported name is the node's first child when
                        // that is a node of its own, else the node's text
                        const first = child + 1;
                        const name_node = if (alias != NONE and first != alias and first < t.end(child)) first else child;
                        var imported = t.text(name_node);
                        if (alias != NONE and name_node == child) imported = imported[0 .. t.nodes[alias].text_start - t.nodes[child].text_start];
                        try names.append(self.arena, .{
                            .imported = std.mem.trim(u8, imported, " \t\r\n"),
                            .node = name_node,
                            .local = if (alias != NONE) alias else child,
                        });
                    }
                }
                import.names = names.items;
                const end_of_import = t.nodes[node].text_end;
                if (names.items.len != 0) {
                    for (names.items) |n| try defs.append(self.arena, .{ .node = n.local, .visible_from = end_of_import });
                } else if (!import.wildcard) {
                    const alias = self.childLabelled(node, sr.import_alias);
                    import.local = if (alias != NONE) alias else module;
                    try defs.append(self.arena, .{ .node = import.local, .visible_from = end_of_import });
                }
                try imports.append(self.arena, import);
            }

            // Imports added definitions after the merged, sorted ones
            if (imports.items.len != 0) std.sort.pdq(scopes_mod.Definition, defs.items, {}, struct {
                fn lt(_: void, a: scopes_mod.Definition, b: scopes_mod.Definition) bool {
                    return a.node < b.node;
                }
            }.lt);
            // A node listed twice (in `define` and as an import's name) defines once
            var kept: usize = 0;
            for (defs.items) |d| {
                if (kept != 0 and defs.items[kept - 1].node == d.node) continue;
                defs.items[kept] = d;
                kept += 1;
            }
            defs.items.len = kept;

            var members: std.ArrayList(scopes_mod.Member) = .empty;
            for (try self.matchAll(sr.members)) |node| {
                const target = self.childLabelled(node, sr.member_target);
                const name = self.childLabelled(node, sr.member_name);
                if (target != NONE and name != NONE) try members.append(self.arena, .{ .node = node, .target = target, .name = name });
            }

            // Nothing inside an import statement is a use: the module's name
            // and the imported names refer to another file
            var kept_uses = uses;
            if (import_nodes.len != 0) {
                const filtered = try self.arena.alloc(u32, uses.len);
                var n: usize = 0;
                var next_import: usize = 0;
                for (uses) |use| {
                    while (next_import < import_nodes.len and t.end(import_nodes[next_import]) <= use) next_import += 1;
                    if (next_import < import_nodes.len and use >= import_nodes[next_import]) continue;
                    filtered[n] = use;
                    n += 1;
                }
                kept_uses = filtered[0..n];
            }

            var input = ScopeInput{
                .rule = sr,
                .scope_nodes = scope_nodes,
                .outside = try self.matchAll(sr.outside),
                .defs = defs.items,
                .uses = kept_uses,
                .members = members.items,
                .imports = imports.items,
            };
            if (self.in_project and (sr.imports.len != 0 or sr.import_all.len != 0)) {
                // What the other files can import: the top-level definitions,
                // those with at most one scope above the scope they are in
                const is_scope = try self.arena.alloc(bool, t.nodes.len);
                @memset(is_scope, false);
                for (scope_nodes) |s| is_scope[s] = true;
                for (defs.items) |d| {
                    // An outer definition belongs one scope further out
                    const allowed: u32 = if (d.outer) 2 else 1;
                    var above: u32 = 0;
                    var p = t.parents[d.node];
                    while (p != NONE and above <= allowed) : (p = t.parents[p]) {
                        if (is_scope[p]) above += 1;
                    }
                    if (above > allowed) continue;
                    if (sr.exports.len != 0 and !self.anyMatches(sr.exports, d.node)) continue;
                    // The first definition of a name is the one exported
                    const entry = try input.exports.getOrPut(self.arena, t.text(d.node));
                    if (!entry.found_existing) entry.value_ptr.* = d.node;
                }
            }
            try self.scope_inputs.append(self.arena, input);
        }

        const FinishError = error{ OutOfMemory, PythonError };

        /// Which file each import of a scopes() rule refers to. Done before
        /// the files are finished in parallel: a resolver is Python code.
        fn resolveImports(self: *Run, index: usize, link: *const Link, file: usize) error{PythonError}!void {
            for (self.scope_inputs.items[index].imports) |*import| {
                import.target = (try link.resolve(file, self.tree.text(import.module))) orelse NONE;
            }
        }

        /// Second pass of a scopes() rule: resolve the imports against the
        /// other files' exports (`link`; null when checking one file alone),
        /// then resolve every name.
        fn finishScopes(self: *Run, index: usize, link: ?*const Link) FinishError!void {
            const t = self.tree;
            const input = &self.scope_inputs.items[index];
            const sr = input.rule;

            const Origin = struct { file: u32, node: u32 };
            var externals: std.ArrayList(scopes_mod.External) = .empty;
            var origins: std.AutoHashMapUnmanaged(u32, Origin) = .empty;
            var modules: std.AutoHashMapUnmanaged(u32, u32) = .empty;
            var import_problems: std.ArrayList(scopes_mod.Problem) = .empty;
            var assume_defined = false;

            for (input.imports) |import| {
                const module_text = t.text(import.module);
                // One file alone: what a module offers is unknown, so is
                // what a wildcard import brings in (resolveImports() found the files)
                const other = if (link != null and import.target != NONE) import.target else {
                    if (link != null) try import_problems.append(self.arena, .{ .kind = .no_module, .node = import.module });
                    if (import.wildcard) assume_defined = true;
                    continue;
                };
                const offered = &link.?.runs[other].scope_inputs.items[index].exports;
                if (import.wildcard) {
                    var it = offered.iterator();
                    while (it.next()) |entry| try externals.append(self.arena, .{ .name = entry.key_ptr.*, .file = other, .node = entry.value_ptr.* });
                } else if (import.names.len != 0) {
                    for (import.names) |name| {
                        if (offered.get(name.imported)) |node| {
                            try origins.put(self.arena, name.local, .{ .file = other, .node = node });
                        } else if (link.?.runs[other].broken) |b| {
                            // (defined in the other file's broken text, probably)
                            if (!b.words.contains(name.imported)) try import_problems.append(self.arena, .{ .kind = .no_export, .node = name.node, .owner = module_text });
                        } else {
                            try import_problems.append(self.arena, .{ .kind = .no_export, .node = name.node, .owner = module_text });
                        }
                    }
                } else try modules.put(self.arena, import.local, other);
            }

            // The Analysis may outlive the Rules: names it keeps must live in its arena
            const builtins = try self.arena.alloc([]const u8, sr.builtins.len);
            for (builtins, sr.builtins) |*slot, name| slot.* = try self.arena.dupe(u8, name);

            var result = try scopes_mod.analyze(self.arena, t, input.scope_nodes, input.defs, input.uses, input.members, builtins, externals.items, .{
                .ordered = sr.ordered,
                .report_unused = sr.levels[@intFromEnum(scopes_mod.ProblemKind.unused)] != .ignore,
                .report_shadowed = sr.levels[@intFromEnum(scopes_mod.ProblemKind.shadowed)] != .ignore,
                .assume_defined = assume_defined,
                .outside = input.outside,
            });

            for (result.symbols.items) |*sym| {
                if (sym.node == NONE) continue;
                if (origins.get(sym.node)) |o| {
                    sym.origin_file = o.file;
                    sym.origin_node = o.node;
                }
                if (modules.get(sym.node)) |m| sym.module = m;
            }

            // `module.name`: look the name up in what the module exports
            var external_index: std.AutoHashMapUnmanaged(u64, u32) = .empty;
            var external_uses: std.ArrayList(struct { symbol: u32, node: u32 }) = .empty;
            for (result.open_members) |m| {
                const owner = result.symbols.items[result.by_node[m.target]];
                if (owner.module == NONE) continue;
                const offered = &link.?.runs[owner.module].scope_inputs.items[index].exports;
                const name = t.text(m.name);
                const node = offered.get(name) orelse {
                    try import_problems.append(self.arena, .{ .kind = .no_member, .node = m.name, .other = owner.node });
                    continue;
                };
                const entry = try external_index.getOrPut(self.arena, (@as(u64, owner.module) << 32) | node);
                if (!entry.found_existing) {
                    entry.value_ptr.* = @intCast(result.symbols.items.len);
                    try result.symbols.append(self.arena, .{ .name = name, .node = NONE, .scope = NONE, .hoisted = true, .origin_file = owner.module, .origin_node = node });
                }
                result.by_node[m.name] = entry.value_ptr.*;
                result.by_node[m.node] = entry.value_ptr.*;
                try external_uses.append(self.arena, .{ .symbol = entry.value_ptr.*, .node = m.name });
            }
            if (external_uses.items.len != 0) {
                // Group them per symbol, in source order
                const Use = @TypeOf(external_uses.items[0]);
                std.sort.pdq(Use, external_uses.items, {}, struct {
                    fn lt(_: void, a: Use, b: Use) bool {
                        return if (a.symbol != b.symbol) a.symbol < b.symbol else a.node < b.node;
                    }
                }.lt);
                const nodes = try self.arena.alloc(u32, external_uses.items.len);
                var start: usize = 0;
                for (external_uses.items, 0..) |u, i| {
                    nodes[i] = u.node;
                    const last = i + 1 == external_uses.items.len or external_uses.items[i + 1].symbol != u.symbol;
                    if (last) {
                        result.symbols.items[u.symbol].uses = nodes[start .. i + 1];
                        start = i + 1;
                    }
                }
            }

            try self.scope_results.append(self.arena, .{ .namespace = try self.arena.dupe(u8, sr.namespace), .result = result });

            for (import_problems.items) |p| try self.reportProblem(sr, p);
            for (result.problems.items) |p| {
                if (self.aboutBrokenName(p)) continue;
                if (p.kind == .undefined and sr.on_unresolved != null) {
                    try self.unresolved.append(self.arena, .{ .rule = sr, .problem = p });
                } else try self.reportProblem(sr, p);
            }
        }

        /// A name that is undefined, unused or not a member, and occurs in
        /// the broken text: it was probably defined or used there.
        fn aboutBrokenName(self: *const Run, p: scopes_mod.Problem) bool {
            const b = self.broken orelse return false;
            return switch (p.kind) {
                .undefined, .unused, .no_member => b.words.contains(self.tree.text(p.node)),
                else => false,
            };
        }

        fn reportProblem(self: *Run, sr: *const ScopeRule, p: scopes_mod.Problem) !void {
            const t = self.tree;
            const k = @intFromEnum(p.kind);
            if (sr.levels[k] == .ignore) return;
            const flat = t.nodes[p.node];
            var v = self.values(p.node);
            v.owner = if (p.owner.len != 0) p.owner else if (p.other != NONE) t.text(p.other) else "";
            var finding = Finding{
                .start = flat.text_start,
                .end = flat.text_end,
                .severity = if (sr.levels[k] == .err) "error" else "warning",
                .code = sr.codes[k],
                .message = try format(self.arena, sr.messages[k], v),
            };
            if (p.other != NONE) {
                finding.note = switch (p.kind) {
                    .shadowed => "the outer definition is here",
                    .no_member => "defined here",
                    else => "first defined here",
                };
                finding.note_start = t.nodes[p.other].text_start;
                finding.note_end = t.nodes[p.other].text_end;
                finding.has_note = true;
            }
            _ = try self.add(finding);
        }

        fn orderU32(a: u32, b: u32) std.math.Order {
            return std.math.order(a, b);
        }

        fn check(self: *Run, rule_idx: usize) !void {
            const cr = &self.state.rules.items[rule_idx];
            // Custom rules run afterwards, from Python; types once the names are resolved
            if (cr.kind == .custom or cr.kind == .types or cr.kind == .flow) return;
            if (cr.scope) |sr| return self.prepareScopes(sr);
            const t = self.tree;
            var chain_buf: [selector.MAX_COMPOUNDS]u32 = undefined;

            switch (cr.kind) {
                .forbid => for (try self.matchAll(cr.selectors)) |node| {
                    _ = try self.report(rule_idx, node, 0);
                },
                .inside => for (try self.matchAll(cr.selectors)) |node| {
                    var ok = false;
                    var p = t.parents[node];
                    while (p != NONE) : (p = t.parents[p]) {
                        if (self.anyMatches(cr.within, p)) {
                            ok = true;
                            break;
                        }
                        if (self.anyMatches(cr.stop_at, p)) break;
                    }
                    if (!ok) _ = try self.report(rule_idx, node, 0);
                },
                .unique => {
                    // Texts must differ within a group: the nearest `within`
                    // ancestor, or else what the selector's first part matched
                    const Match = struct { node: u32, group: u32 };
                    var found: std.ArrayList(Match) = .empty;
                    for (cr.selectors) |*sel| {
                        const chain = chain_buf[0..sel.compounds.len];
                        for (try self.candidates(sel.compounds[sel.compounds.len - 1])) |node| {
                            if (!sel.matches(t, node, chain)) continue;
                            const group = if (cr.within.len != 0) self.groupOf(cr.within, node) else if (sel.compounds.len > 1) chain[0] else NONE;
                            try found.append(self.arena, .{ .node = node, .group = group });
                        }
                    }
                    std.sort.pdq(Match, found.items, {}, struct {
                        fn lt(_: void, a: Match, b: Match) bool {
                            return a.node < b.node;
                        }
                    }.lt);

                    const Key = struct { group: u32, text: []const u8 };
                    const Ctx = struct {
                        pub fn hash(_: @This(), k: Key) u64 {
                            return std.hash.Wyhash.hash(k.group, k.text);
                        }
                        pub fn eql(_: @This(), a: Key, b: Key) bool {
                            return a.group == b.group and std.mem.eql(u8, a.text, b.text);
                        }
                    };
                    var seen: std.HashMapUnmanaged(Key, u32, Ctx, 80) = .empty;
                    var previous: u32 = NONE;
                    for (found.items) |m| {
                        if (m.node == previous) continue; // matched by two alternatives
                        previous = m.node;
                        const entry = try seen.getOrPut(self.arena, .{ .group = m.group, .text = t.text(m.node) });
                        if (!entry.found_existing) {
                            entry.value_ptr.* = m.node;
                            continue;
                        }
                        const first = t.nodes[entry.value_ptr.*];
                        const finding = try self.report(rule_idx, m.node, 0) orelse continue;
                        finding.note = "first one is here";
                        finding.note_start = first.text_start;
                        finding.note_end = first.text_end;
                        finding.has_note = true;
                    }
                },
                .require => for (cr.selectors) |*sel| {
                    // Every node matching all but the last part needs a match
                    // of the whole selector attached to it
                    const chain = chain_buf[0..sel.compounds.len];
                    var satisfied: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    for (try self.candidates(sel.compounds[sel.compounds.len - 1])) |node| {
                        if (sel.matches(t, node, chain)) try satisfied.put(self.arena, chain[chain.len - 2], {});
                    }
                    const parent_sel = sel.prefix();
                    for (try self.candidates(sel.compounds[sel.compounds.len - 2])) |node| {
                        if (!satisfied.contains(node) and parent_sel.matches(t, node, null)) _ = try self.report(rule_idx, node, 0);
                    }
                },
                .count => {
                    var counts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
                    if (cr.within.len != 0) {
                        // Count per nearest `within` ancestor
                        for (try self.matchAll(cr.selectors)) |node| {
                            const group = self.groupOf(cr.within, node);
                            if (group == NONE) continue;
                            const entry = try counts.getOrPut(self.arena, group);
                            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
                        }
                        for (try self.matchAll(cr.within)) |group| {
                            const n = counts.get(group) orelse 0;
                            if (n < cr.min or n > cr.max) _ = try self.report(rule_idx, group, n);
                        }
                        return;
                    }
                    for (cr.selectors) |*sel| {
                        if (sel.compounds.len == 1) {
                            // No anchor: count over the whole tree
                            var total: u32 = 0;
                            for (try self.candidates(sel.compounds[0])) |node| total += @intFromBool(sel.matches(t, node, null));
                            if (t.nodes.len != 0 and (total < cr.min or total > cr.max)) _ = try self.report(rule_idx, 0, total);
                            continue;
                        }
                        const chain = chain_buf[0..sel.compounds.len];
                        counts.clearRetainingCapacity();
                        for (try self.candidates(sel.compounds[sel.compounds.len - 1])) |node| {
                            if (!sel.matches(t, node, chain)) continue;
                            const entry = try counts.getOrPut(self.arena, chain[0]);
                            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
                        }
                        for (try self.candidates(sel.compounds[0])) |node| {
                            if (!sel.anchorMatches(t, node)) continue;
                            const n = counts.get(node) orelse 0;
                            if (n < cr.min or n > cr.max) _ = try self.report(rule_idx, node, n);
                        }
                    }
                },
                .scopes, .custom, .types, .flow => unreachable,
            }
        }
    };

    /// Offsets where each line starts, for line and column lookups.
    fn lineStarts(arena: std.mem.Allocator, input: []const u8) ![]const u32 {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        var from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, input, from, '\n')) |nl| {
            try starts.append(arena, @intCast(nl + 1));
            from = nl + 1;
        }
        return starts.items;
    }

    /// 1-based line and column (in bytes) of `pos`.
    fn lineCol(lines: []const u32, pos: u32) struct { line: u32, col: u32 } {
        // The last line starting at or before pos
        var lo: usize = 0;
        var hi: usize = lines.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (lines[mid] <= pos) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo + 1), .col = pos - lines[lo] + 1 };
    }

    /// Diagnostic(severity, code, message, (start, end), line, column, notes)
    fn diagnostic(cls: *PyObject, severity: []const u8, code: []const u8, message: []const u8, start: u32, end: u32, lines: []const u32, notes: ?*PyObject) ?*PyObject {
        const lc = lineCol(lines, start);
        const no_notes: ?*PyObject = if (notes == null) py.c.PyList_New(0) orelse return null else null;
        defer if (no_notes) |l| py.Py_DecRef(l);
        const args = py.c.Py_BuildValue(
            "(s#s#s#(II)IIO)",
            severity.ptr,
            @as(py.Py_ssize_t, @intCast(severity.len)),
            code.ptr,
            @as(py.Py_ssize_t, @intCast(code.len)),
            message.ptr,
            @as(py.Py_ssize_t, @intCast(message.len)),
            start,
            end,
            lc.line,
            lc.col,
            notes orelse no_notes.?,
        ) orelse return null;
        defer py.Py_DecRef(args);
        return py.c.PyObject_Call(cls, args, null);
    }

    /// The part of a check that calls into Python, once the symbols exist:
    /// on_unresolved functions for undefined names, then custom rules.
    fn runPython(run: *Run, tree_obj: *PyObject, analysis_obj: *PyObject) bool {
        var any = run.unresolved.items.len != 0;
        for (run.state.rules.items) |r| any = any or r.kind == .custom;
        if (!any) return true;

        py.Py_IncRef(analysis_obj);
        const ctx_obj = Module.toPy(Context, .{ ._run = run, ._analysis = analysis_obj }) orelse {
            py.Py_DecRef(analysis_obj);
            return false;
        };
        defer py.Py_DecRef(ctx_obj);
        const ctx = Module.fromPy(*Context, ctx_obj) catch return false;
        // After this check the context must not reach into freed memory
        defer {
            ctx._run = null;
            ctx._code = "custom";
        }

        for (run.unresolved.items) |u| {
            const k = @intFromEnum(u.problem.kind);
            ctx._code = u.rule.codes[k];
            const node_obj = py.c.PyObject_CallMethod(tree_obj, "node", "I", u.problem.node) orelse return false;
            defer py.Py_DecRef(node_obj);
            const result = py.c.PyObject_CallFunctionObjArgs(u.rule.on_unresolved.?, node_obj, ctx_obj, @as(?*PyObject, null)) orelse return false;
            defer py.Py_DecRef(result);
            const known = py.c.PyObject_IsTrue(result);
            if (known < 0) return false;
            if (known == 0) run.reportProblem(u.rule, u.problem) catch return oomObject() != null;
        }

        for (run.state.rules.items) |*r| {
            const function = r.callback orelse continue;
            ctx._code = r.code;
            const nodes = run.matchAll(r.selectors) catch return oomObject() != null;
            for (nodes) |node| {
                const node_obj = py.c.PyObject_CallMethod(tree_obj, "node", "I", node) orelse return false;
                defer py.Py_DecRef(node_obj);
                const result = py.c.PyObject_CallFunctionObjArgs(function, node_obj, ctx_obj, @as(?*PyObject, null)) orelse return false;
                py.Py_DecRef(result);
            }
        }
        return true;
    }

    /// Check a tree and return everything found: diagnostics and symbols.
    pub fn analyze(self: *Rules, args: pyoz.Args(struct { source: *PyObject, recover: bool = false })) pyoz.Signature(?*PyObject, "Analysis") {
        var out: [1]*PyObject = undefined;
        if (!self.analyzeFiles(&.{args.value.source}, null, null, args.value.recover, &out)) return .{ .value = null };
        return .{ .value = out[0] };
    }

    /// Check a tree (a zgram Tree or Node, or source text to parse first,
    /// with syntax error recovery if `recover`) against the rules. Returns
    /// the diagnostics in source order.
    pub fn check(self: *Rules, args: pyoz.Args(struct { source: *PyObject, recover: bool = false })) pyoz.Signature(?*PyObject, "list[Diagnostic]") {
        var out: [1]*PyObject = undefined;
        if (!self.analyzeFiles(&.{args.value.source}, null, null, args.value.recover, &out)) return .{ .value = null };
        defer py.Py_DecRef(out[0]);
        return .{ .value = py.c.PyObject_GetAttrString(out[0], "diagnostics") };
    }

    /// Check several files together: imports between them are resolved.
    /// `files` maps a key (usually a module name or a path) to a source.
    pub fn analyze_project(self: *Rules, args: pyoz.Args(struct { files: *PyObject, resolve: ?*PyObject = null, recover: bool = false })) pyoz.Signature(?*PyObject, "Project") {
        const files = args.value.files;
        if (!py.PyDict_Check(files)) {
            raise(py.PyExc_TypeError(), "files must be a dict of key -> source (a zgram Tree or Node, or text)", .{});
            return .{ .value = null };
        }
        var resolver = args.value.resolve;
        if (resolver) |r| {
            if (r == py.Py_None()) resolver = null else if (py.c.PyCallable_Check(r) == 0) {
                raise(py.PyExc_TypeError(), "resolve must be callable: resolve(module, importing_file) -> file or None", .{});
                return .{ .value = null };
            }
        }
        const n: usize = @intCast(py.c.PyDict_Size(files));
        const keys = allocator.alloc(*PyObject, n) catch return .{ .value = oomObject() };
        defer allocator.free(keys);
        const sources = allocator.alloc(*PyObject, n) catch return .{ .value = oomObject() };
        defer allocator.free(sources);
        const out = allocator.alloc(*PyObject, n) catch return .{ .value = oomObject() };
        defer allocator.free(out);
        var pos: py.Py_ssize_t = 0;
        var key: ?*PyObject = null;
        var value: ?*PyObject = null;
        var i: usize = 0;
        while (py.c.PyDict_Next(files, &pos, &key, &value) != 0 and i < n) : (i += 1) {
            keys[i] = key.?;
            sources[i] = value.?;
        }
        if (!self.analyzeFiles(sources[0..i], keys[0..i], resolver, args.value.recover, out)) return .{ .value = null };
        defer for (out[0..i]) |obj| py.Py_DecRef(obj);

        const analyses = py.c.PyDict_New() orelse return .{ .value = null };
        for (keys[0..i], out[0..i]) |k, analysis| {
            if (py.PyDict_SetItem(analyses, k, analysis) != 0) {
                py.Py_DecRef(analyses);
                return .{ .value = null };
            }
        }
        return .{ .value = Module.toPy(Project, .{ ._analyses = analyses }) orelse blk: {
            py.Py_DecRef(analyses);
            break :blk null;
        } };
    }

    /// One file of a check: its Analysis object (which owns the tree and
    /// the arena everything else here lives in) and the state of its run
    const File = struct {
        analysis_obj: *PyObject,
        analysis: *Analysis,
        data: *AnalysisData,
        run: *Run,
        input: []const u8,
    };

    /// One more thread per this many nodes, up to MAX_THREADS: measured on
    /// 26K to 1.6M-node projects. Fewer, and starting threads costs more
    /// than they save; more, and they contend for the allocator and memory.
    const NODES_PER_THREAD = 25_000;
    const MAX_THREADS = 8;

    /// Run `job.run(i)` for every file i: on several threads (with the GIL
    /// released) when there are several files and enough work, else here.
    /// False if a job failed (out of memory).
    fn forEachFile(n: usize, total_nodes: usize, job: anytype) bool {
        const threads = @min(n, std.Thread.getCpuCount() catch 1, MAX_THREADS, total_nodes / NODES_PER_THREAD);
        if (threads <= 1) {
            for (0..n) |i| job.run(i) catch return false;
            return true;
        }
        const Shared = struct {
            job: @TypeOf(job),
            n: usize,
            next: std.atomic.Value(usize) = .init(0),
            failed: std.atomic.Value(bool) = .init(false),

            fn work(self: *@This()) void {
                while (!self.failed.load(.monotonic)) {
                    const i = self.next.fetchAdd(1, .monotonic);
                    if (i >= self.n) return;
                    self.job.run(i) catch self.failed.store(true, .monotonic);
                }
            }

            fn all(self: *@This(), wanted: usize) void {
                var handles: [MAX_THREADS]std.Thread = undefined;
                var started: usize = 0;
                for (0..wanted - 1) |_| {
                    // Fewer threads than asked for is fine: this one works too
                    handles[started] = std.Thread.spawn(.{}, work, .{self}) catch break;
                    started += 1;
                }
                self.work();
                for (handles[0..started]) |h| h.join();
            }
        };
        var shared = Shared{ .job = job, .n = n };
        pyoz.allowThreads(Shared.all, .{ &shared, threads });
        return !shared.failed.load(.monotonic);
    }

    const PrepareJob = struct {
        files: []const File,
        rules: usize,

        fn run(self: PrepareJob, i: usize) !void {
            const r = self.files[i].run;
            try r.buildIndex();
            for (0..self.rules) |index| try r.check(index);
        }
    };

    const NamesJob = struct {
        files: []const File,
        link: ?*const Link,

        fn run(self: NamesJob, i: usize) !void {
            const r = self.files[i].run;
            for (0..r.scope_inputs.items.len) |index| try r.finishScopes(index, self.link);
        }
    };

    const PrepareTypesJob = struct {
        files: []const File,
        checkers: []const *types_mod.Checker,
        rule: *const TypeRule,

        fn run(self: PrepareTypesJob, i: usize) !void {
            const checker = self.checkers[i];
            checker.in = try self.files[i].run.typeInputs(self.rule, self.files[i].data.typed_result);
            checker.prepare() catch return error.OutOfMemory;
        }
    };

    const TypesJob = struct {
        checkers: []const *types_mod.Checker,

        fn run(self: TypesJob, i: usize) !void {
            const checker = self.checkers[i];
            // The depth bookkeeping of this thread, not the shared one
            const work = try checker.arena.create(types_mod.Work);
            work.* = .{ .arena = checker.arena };
            checker.work = work;
            try checker.check();
            try checker.complete();
        }
    };

    const FlowJob = struct {
        files: []const File,
        rules: []const CompiledRule,

        fn run(self: FlowJob, i: usize) !void {
            for (self.rules) |r| {
                if (r.flow) |fr| try self.files[i].run.runFlow(fr);
            }
        }
    };

    /// Check `sources` together. `keys` names them (null: one file checked
    /// alone, whose imports can't be followed). On success `out` receives a
    /// new reference to each file's Analysis.
    fn analyzeFiles(self: *Rules, sources: []const *PyObject, keys: ?[]const *PyObject, resolver: ?*PyObject, recover: bool, out: []*PyObject) bool {
        const state = self._state orelse {
            raise(py.PyExc_RuntimeError(), "Rules is not initialized", .{});
            return false;
        };
        const files = allocator.alloc(File, sources.len) catch return oomObject() != null;
        defer allocator.free(files);
        var opened: usize = 0;
        var done = false;
        defer if (!done) {
            for (files[0..opened]) |f| py.Py_DecRef(f.analysis_obj);
        };
        for (sources) |source| {
            files[opened] = self.openFile(state, source, recover) orelse return false;
            files[opened].run.in_project = keys != null;
            opened += 1;
        }

        // The native passes below touch only their own file (and read what
        // the others have finished): they run in parallel, without the GIL
        var total_nodes: usize = 0;
        for (files) |f| total_nodes += f.run.tree.nodes.len;

        // Pass 1: the structural rules, and what each file defines and exports
        if (!forEachFile(files.len, total_nodes, PrepareJob{ .files = files, .rules = state.rules.items.len })) return oomObject() != null;

        // Pass 2: names, with the imports resolved against the other files
        const runs = allocator.alloc(*Run, files.len) catch return oomObject() != null;
        defer allocator.free(runs);
        var link = Link{ .runs = runs, .keys = keys orelse &.{}, .resolver = resolver };
        defer link.by_text.deinit(allocator);
        defer if (link.by_key) |d| py.Py_DecRef(d);
        if (keys != null and resolver != null) link.by_key = py.c.PyDict_New() orelse return false;
        for (files, 0..) |f, i| {
            runs[i] = f.run;
            const ks = keys orelse continue;
            if (link.by_key) |d| {
                const index = py.c.PyLong_FromUnsignedLong(@intCast(i)) orelse return false;
                defer py.Py_DecRef(index);
                if (py.PyDict_SetItem(d, ks[i], index) != 0) return false;
            }
            if (!py.PyUnicode_Check(ks[i])) continue;
            var len: py.Py_ssize_t = 0;
            const ptr = py.c.PyUnicode_AsUTF8AndSize(ks[i], &len) orelse {
                py.c.PyErr_Clear();
                continue;
            };
            const entry = link.by_text.getOrPut(allocator, ptr[0..@intCast(len)]) catch return oomObject() != null;
            if (!entry.found_existing) entry.value_ptr.* = @intCast(i);
        }
        // Which file each import names (a resolver is Python: here, with the GIL)
        if (keys != null) {
            for (files, 0..) |f, file_index| {
                for (0..f.run.scope_inputs.items.len) |index| {
                    f.run.resolveImports(index, &link, file_index) catch return false;
                }
            }
        }
        if (!forEachFile(files.len, total_nodes, NamesJob{ .files = files, .link = if (keys != null) &link else null })) return oomObject() != null;

        // Types, once every file's names are resolved (the files' checkers
        // work out each other's types: one thread), and flow
        if (!runTypes(state, files)) return false;
        if (!forEachFile(files.len, total_nodes, FlowJob{ .files = files, .rules = state.rules.items })) return oomObject() != null;

        // Pass 3: the parts that call into Python, and the diagnostics
        var key_share: ?*KeyShare = null;
        if (keys) |ks| {
            const share = allocator.create(KeyShare) catch return oomObject() != null;
            share.* = .{ .refs = 1, .keys = allocator.dupe(*PyObject, ks) catch {
                allocator.destroy(share);
                return oomObject() != null;
            } };
            for (share.keys) |k| py.Py_IncRef(k);
            key_share = share;
        }
        // Ours until here; the files that took it keep it
        defer if (key_share) |share| share.release();
        for (files) |f| {
            if (!finishFile(f, key_share)) return false;
        }
        for (files, 0..) |f, i| out[i] = f.analysis_obj;
        done = true;
        return true;
    }

    /// Type-check the files with the rules' types() rule, if there is one.
    /// The files share one table of types, so that a type crossing an import
    /// is the same on both sides.
    fn runTypes(state: *State, files: []const File) bool {
        var found: ?*const TypeRule = null;
        for (state.rules.items) |r| {
            if (r.types) |tr| found = found orelse tr;
        }
        const tr = found orelse return true;
        if (files.len == 0) return true;

        const share = allocator.create(TypeShare) catch return oomObject() != null;
        share.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .table = undefined };
        // Until a file holds it, it is ours to free
        var attached: usize = 0;
        defer if (attached == 0) {
            share.arena.deinit();
            allocator.destroy(share);
        };
        share.table = types_mod.Table.init(share.arena.allocator()) catch return oomObject() != null;

        const share_arena = share.arena.allocator();
        const checkers = share_arena.alloc(*types_mod.Checker, files.len) catch return oomObject() != null;
        // The types the options mention: read once for every file
        const literal_texts = share_arena.alloc([]const u8, tr.literals.len) catch return oomObject() != null;
        for (literal_texts, tr.literals) |*slot, lit| slot.* = lit.type;
        const opts = share_arena.create(types_mod.Options) catch return oomObject() != null;
        // (`fn(int)` in the options returns this)
        share.table.void_name = tr.names.void;
        opts.* = types_mod.readOptions(&share.table, share_arena, .{
            .literal_types = literal_texts,
            .operators = tr.operators,
            .basic = tr.basic,
            .coerce = tr.coerce,
            .builtins = tr.builtins,
            .names = tr.names,
        }) catch |e| {
            if (e == error.OutOfMemory) _ = py.c.PyErr_NoMemory() else raise(py.PyExc_ValueError(), "types(): a type in the rule's options could not be read", .{});
            return false;
        };
        for (files, 0..) |f, i| {
            const run = f.run;
            // The scopes() rule whose names are typed
            var result_index: ?usize = null;
            for (run.scope_results.items, 0..) |result, r| {
                if (tr.namespace.len == 0 or std.mem.eql(u8, result.namespace, tr.namespace)) {
                    result_index = r;
                    break;
                }
            }
            const r = result_index orelse {
                raise(py.PyExc_ValueError(), "types() needs a scopes() rule{s}{s}{s}", .{
                    if (tr.namespace.len != 0) " with namespace '" else "",
                    tr.namespace,
                    if (tr.namespace.len != 0) "'" else "",
                });
                return false;
            };
            const checker = run.arena.create(types_mod.Checker) catch return oomObject() != null;
            checker.* = .{
                .arena = run.arena,
                .table = &share.table,
                .tree = run.tree,
                .names = &run.scope_results.items[r].result,
                .in = .{ .labels = tr.labels },
                .file = @intCast(i),
                .others = checkers,
                .work = &share.table.work,
                .opts = opts,
            };
            checkers[i] = checker;
            f.data.checker = checker;
            f.data.typed_result = r;
        }
        var total_nodes: usize = 0;
        for (files) |f| total_nodes += f.run.tree.nodes.len;
        // Each file's inputs and tables, in parallel (the options' types were
        // read when the rules were compiled: reading them again can't fail)
        if (!forEachFile(files.len, total_nodes, PrepareTypesJob{ .files = files, .checkers = checkers, .rule = tr })) return oomObject() != null;
        // Every checker exists before any runs: they ask each other about
        // imported names. First, on this thread, what each file offers the
        // others; then every file checks its own code, in parallel.
        for (checkers) |checker| checker.prepareExports() catch return oomObject() != null;
        if (!forEachFile(files.len, total_nodes, TypesJob{ .checkers = checkers })) return oomObject() != null;

        for (files, checkers) |f, checker| {
            for (checker.problems.items) |p| {
                const k = @intFromEnum(p.kind);
                if (tr.ignore[k]) continue;
                const flat = f.run.tree.nodes[p.node];
                _ = f.run.add(.{
                    .start = flat.text_start,
                    .end = flat.text_end,
                    .severity = f.run.arena.dupe(u8, tr.severity) catch return oomObject() != null,
                    .code = f.run.arena.dupe(u8, tr.codes[k]) catch return oomObject() != null,
                    .message = p.message,
                }) catch return oomObject() != null;
            }
            f.data.type_share = share;
            share.refs += 1;
            attached += 1;
        }
        return true;
    }

    /// Read a source's tree through its capsule and set up its run.
    fn openFile(self: *Rules, state: *State, source: *PyObject, recover: bool) ?File {
        // Text is parsed first (recovering from syntax errors if asked); a
        // Node stands for its Tree
        var tree_obj: *PyObject = undefined;
        if (py.PyUnicode_Check(source) or py.PyBytes_Check(source)) {
            tree_obj = (if (recover) parseRecovering(self._parser.?, source) else py.c.PyObject_CallMethod(self._parser.?, "parse_tree", "O", source)) orelse return null;
        } else if (py.c.PyObject_HasAttrString(source, "capsule") != 0) {
            tree_obj = source;
            py.Py_IncRef(tree_obj);
        } else {
            tree_obj = py.c.PyObject_GetAttrString(source, "tree") orelse {
                py.c.PyErr_Clear();
                raise(py.PyExc_TypeError(), "expected a zgram Tree or Node, or source text", .{});
                return null;
            };
        }
        defer py.Py_DecRef(tree_obj);

        const capsule = py.c.PyObject_GetAttrString(tree_obj, "capsule") orelse return null;
        defer py.Py_DecRef(capsule);
        const view: *const tree_mod.TreeView = @ptrCast(@alignCast(py.c.PyCapsule_GetPointer(capsule, tree_mod.CAPSULE_NAME) orelse return null));
        if (view.abi != tree_mod.TREE_ABI) {
            raise(py.PyExc_RuntimeError(), "this zrules reads zgram trees with TREE_ABI {d}, but the tree has {d}: upgrade zrules or zgram", .{ tree_mod.TREE_ABI, view.abi });
            return null;
        }
        // The tree must come from the grammar the rules were compiled against
        var same = view.rule_count == state.names.rules.len and view.field_count == state.names.fields.len;
        if (same) {
            for (state.names.rules, 0..) |name, i| same = same and std.mem.eql(u8, name, view.rule_names.?[i].slice());
        }
        if (!same) {
            raise(py.PyExc_ValueError(), "the tree was parsed with a different grammar than these rules were compiled against", .{});
            return null;
        }

        // The check runs in an arena that the Analysis keeps: the names it
        // found stay there, and Symbol objects are made from them on demand
        const data = allocator.create(AnalysisData) catch return oomFile();
        data.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        py.Py_IncRef(tree_obj);
        const analysis_obj = Module.toPy(Analysis, .{ ._tree = tree_obj, ._data = data }) orelse {
            py.Py_DecRef(tree_obj);
            data.destroy();
            return null;
        };
        var done = false;
        defer if (!done) py.Py_DecRef(analysis_obj);
        const analysis = Module.fromPy(*Analysis, analysis_obj) catch return null;
        const arena = data.arena.allocator();

        const nodes: []const tree_mod.FlatNode = if (view.nodes) |n| n[0..view.node_count] else &.{};
        const input: []const u8 = if (view.input) |p| p[0..view.input_len] else "";
        const tree = arena.create(Tree) catch return oomFile();
        tree.* = .{
            .nodes = nodes,
            .input = input,
            .parents = Tree.computeParents(arena, nodes) catch return oomFile(),
        };
        data.nodes = nodes;
        const run = arena.create(Run) catch return oomFile();
        run.* = .{ .arena = arena, .state = state, .tree = tree };
        const offsets = syntaxErrorOffsets(arena, tree_obj) orelse return null;
        if (offsets.len != 0) run.broken = Broken.init(arena, tree, state.names.rules.len, offsets) catch return oomFile();

        done = true;
        return .{ .analysis_obj = analysis_obj, .analysis = analysis, .data = data, .run = run, .input = input };
    }

    /// parser.parse_tree(source, recover=True)
    fn parseRecovering(parser: *PyObject, source: *PyObject) ?*PyObject {
        const method = py.c.PyObject_GetAttrString(parser, "parse_tree") orelse return null;
        defer py.Py_DecRef(method);
        const args = py.c.PyTuple_Pack(1, source) orelse return null;
        defer py.Py_DecRef(args);
        const kwargs = py.c.Py_BuildValue("{s:O}", "recover", py.Py_True()) orelse return null;
        defer py.Py_DecRef(kwargs);
        return py.c.PyObject_Call(method, args, kwargs);
    }

    /// Where the syntax errors of a tree parsed with recover=True are
    /// (tree.errors, zgram 0.3+), sorted; empty for any other tree. Null
    /// with an exception set on failure.
    fn syntaxErrorOffsets(arena: std.mem.Allocator, tree_obj: *PyObject) ?[]const u32 {
        const errors = py.c.PyObject_GetAttrString(tree_obj, "errors") orelse {
            py.c.PyErr_Clear();
            return &.{};
        };
        defer py.Py_DecRef(errors);
        if (!py.PyList_Check(errors)) return &.{};
        const n: usize = @intCast(py.c.PyList_Size(errors));
        const offsets = arena.alloc(u32, n) catch {
            _ = py.c.PyErr_NoMemory();
            return null;
        };
        for (offsets, 0..) |*slot, i| {
            const span = py.c.PyObject_GetAttrString(py.c.PyList_GetItem(errors, @intCast(i)), "span") orelse return null;
            defer py.Py_DecRef(span);
            const start = py.c.PySequence_GetItem(span, 0) orelse return null;
            defer py.Py_DecRef(start);
            const value = py.c.PyLong_AsUnsignedLong(start);
            if (py.c.PyErr_Occurred() != null) return null;
            slot.* = @intCast(@min(value, std.math.maxInt(u32)));
        }
        std.sort.pdq(u32, offsets, {}, std.sort.asc(u32));
        return offsets;
    }

    fn oomFile() ?File {
        _ = py.c.PyErr_NoMemory();
        return null;
    }

    /// Last pass for one file: hand the names to its Analysis, run the rules
    /// written in Python, and turn the findings into Diagnostic objects.
    fn finishFile(f: File, keys: ?*KeyShare) bool {
        const run = f.run;
        const arena = run.arena;

        const objects = arena.alloc([]?*PyObject, run.scope_results.items.len) catch return oomObject() != null;
        for (objects, run.scope_results.items) |*slot, result| {
            slot.* = arena.alloc(?*PyObject, result.result.symbols.items.len) catch return oomObject() != null;
            @memset(slot.*, null);
        }
        f.data.results = run.scope_results.items;
        f.data.objects = objects;
        if (keys) |share| {
            share.refs += 1;
            f.data.key_share = share;
            f.data.keys = share.keys;
        }

        if (!runPython(run, f.analysis._tree.?, f.analysis_obj)) return false;

        std.sort.pdq(Finding, run.findings.items, {}, Finding.before);

        const zgram = py.c.PyImport_ImportModule("zgram") orelse return false;
        defer py.Py_DecRef(zgram);
        const cls = py.c.PyObject_GetAttrString(zgram, "Diagnostic") orelse return false;
        defer py.Py_DecRef(cls);

        const lines: []const u32 = if (run.findings.items.len == 0) &.{} else lineStarts(arena, f.input) catch return oomObject() != null;
        // A recovered tree's syntax errors come first at a position, among
        // the findings in source order: one list for everything wrong
        const syntax: ?*PyObject = if (run.broken != null) py.c.PyObject_GetAttrString(f.analysis._tree.?, "errors") orelse return false else null;
        defer if (syntax) |s| py.Py_DecRef(s);
        // (the list read in openFile: its offsets are broken.offsets)
        const syntax_count: usize = if (syntax) |s| @min(@as(usize, @intCast(py.c.PyList_Size(s))), run.broken.?.offsets.len) else 0;
        const list = py.c.PyList_New(@intCast(run.findings.items.len + syntax_count)) orelse return false;
        var next_syntax: usize = 0;
        var out: usize = 0;
        for (run.findings.items) |finding| {
            while (next_syntax < syntax_count and run.broken.?.offsets[next_syntax] <= finding.start) : (next_syntax += 1) {
                const d = py.c.PyList_GetItem(syntax.?, @intCast(next_syntax));
                py.Py_IncRef(d);
                _ = py.c.PyList_SetItem(list, @intCast(out), d);
                out += 1;
            }
            var notes: ?*PyObject = null;
            defer if (notes) |n| py.Py_DecRef(n);
            if (finding.has_note) {
                const note_obj = diagnostic(cls, "note", "", finding.note, finding.note_start, finding.note_end, lines, null) orelse {
                    py.Py_DecRef(list);
                    return false;
                };
                notes = py.c.PyList_New(1);
                if (notes) |n| _ = py.c.PyList_SetItem(n, 0, note_obj) else {
                    py.Py_DecRef(note_obj);
                    py.Py_DecRef(list);
                    return false;
                }
            }
            const d = diagnostic(cls, finding.severity, finding.code, finding.message, finding.start, finding.end, lines, notes) orelse {
                py.Py_DecRef(list);
                return false;
            };
            _ = py.c.PyList_SetItem(list, @intCast(out), d);
            out += 1;
        }
        while (next_syntax < syntax_count) : (next_syntax += 1) {
            const d = py.c.PyList_GetItem(syntax.?, @intCast(next_syntax));
            py.Py_IncRef(d);
            _ = py.c.PyList_SetItem(list, @intCast(out), d);
            out += 1;
        }
        f.analysis._diagnostics = list;
        return true;
    }

    pub const __doc__: [*:0]const u8 = "Rules(parser, rules=None): rules compiled against a zgram parser's grammar. check(source) returns the zgram.Diagnostic of every violation, in source order; analyze(source) also returns the symbols found by scopes() rules.";
    pub const check__doc__: [*:0]const u8 = "Check a zgram Tree or Node (or source text, parsed first; with recover=True a syntax error doesn't raise) against the rules. Returns a list of zgram.Diagnostic in source order. For a tree parsed with recover=True, its syntax errors are in the list, and nothing is reported about the broken text.";
    pub const analyze__doc__: [*:0]const u8 = "Like check(), but returns an Analysis: diagnostics, tree, symbols, and resolve(node) / at(offset) to look names up.";
    pub const analyze_project__doc__: [*:0]const u8 = "Check several files together, resolving the imports between them. files is a dict of key -> source; resolve(module_text, importing_key) returns the key of the file a module name refers to, or None (default: the module's text, without quotes, is the key); recover=True parses text sources with syntax error recovery. Returns a Project.";
    pub const add__doc__: [*:0]const u8 = "Add a custom rule: function(node, ctx) is called for every node matching the selector. Returns the function.";
    pub const rule__doc__: [*:0]const u8 = "Decorator form of add(): @rules.rule('Call') above a function(node, ctx).";
};

// ============================================================================
// Module
// ============================================================================

fn version() []const u8 {
    return @import("build_options").version;
}

pub const Module = pyoz.module(.{
    .name = "zrules",
    .doc = "zrules - static rules over zgram parse trees: selectors, context and uniqueness rules, scopes and names, diagnostics.",
    .consts = &.{
        pyoz.constant("TREE_ABI", @as(i64, tree_mod.TREE_ABI)),
    },
    .funcs = &.{
        pyoz.func("inside", inside, "inside(selector, within, stop_at=None, message=None, code=None, severity=None): every node matching `selector` must have an ancestor matching one of `within`, found before an ancestor matching one of `stop_at`."),
        pyoz.func("unique", unique, "unique(selector, message=None, code=None, severity=None): the texts of the nodes matching `selector` must differ within the node its first part matched (the whole tree for a one-part selector)."),
        pyoz.func("forbid", forbid, "forbid(selector, message=None, code=None, severity=None): no node may match `selector`."),
        pyoz.func("require", require, "require(selector, message=None, code=None, severity=None): every node matching all but the last part of `selector` must have a match of the whole selector."),
        pyoz.func("count", count, "count(selector, exactly=None, min=None, max=None, message=None, code=None, severity=None): the number of matches within the node the selector's first part matched must be in range."),
        pyoz.func("scopes", scopes, "scopes(scope, define, use, define_outer=None, hoist=None, after=None, outside=None, builtins=None, ordered=True, namespace='name', on_undefined='error', on_redefine='error', on_unused='ignore', on_shadow='ignore', on_no_member='error', members=None, member_labels=('target', 'name'), imports=None, import_all=None, import_labels=('module', 'names', 'alias'), exports=None, on_no_module='error', on_no_export='error', on_unresolved=None, messages=None, codes=None): resolve names. `scope` nodes open a scope; `define` nodes define their text as a name in the scope around them (`define_outer`: in the scope outside that one); `use` nodes must resolve to a definition. `hoist` definitions are visible before their position; `after` definitions only once their parent node has ended. `members` nodes are accesses like a.b: the child labelled name is looked up in the scope that the child labelled target names."),
        pyoz.func("custom", custom, "custom(selector, function, code=None): call function(node, ctx) for every node matching `selector`."),
        pyoz.func("types", types, "types(basic=None, coerce=None, literals=None, containers=None, names=None, type_names=None, type_args=None, optional=None, variables=None, functions=None, structs=None, binary=None, unary=None, calls=None, index=None, assigns=None, returns=None, conditions=None, operators=None, builtins=None, labels=None, namespace=None, severity='error', codes=None, ignore=None): type-check the program. Each option names the nodes that play a role (selectors), read through labelled children; see the documentation. Needs a scopes() rule for the names."),
        pyoz.func("flow", flow, "flow(sequences, functions=None, branches=None, arms=None, otherwise=None, loops=None, forever=None, at_least_once=None, exits=None, breaks=None, continues=None, must_return=None, variables=None, assigns=None, labels=None, namespace=None, on_unreachable='warning', on_missing_return='error', on_unassigned='error', messages=None, codes=None): follow the control flow. Reports code that can't be reached, `must_return` functions whose end can be, and variables (declared by `variables` without a value, or defined by `assigns`) used before they have a value on every path."),
        pyoz.func("version", version, "Return the zrules version string"),
    },
    .classes = &.{
        pyoz.class("Rule", Rule),
        pyoz.class("Rules", Rules),
        pyoz.class("Analysis", Analysis),
        pyoz.class("Symbol", Symbol),
        pyoz.class("Context", Context),
        pyoz.class("Project", Project),
        pyoz.class("Selector", SelectorObject),
    },
});

// Required: forces analysis of all pub decls so PyInit_ is exported.
comptime {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        _ = @field(@This(), decl.name);
    }
}
