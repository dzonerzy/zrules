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

const Kind = enum(u8) { inside, unique, forbid, require, count, scopes, custom };

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
        .{ "selector", a.selector }, .{ "within", a.within },   .{ "stop_at", a.stop_at },
        .{ "message", a.message },   .{ "code", a.code },       .{ "severity", a.severity },
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
        .{ "scope", a.scope },               .{ "define", a.define },           .{ "use", a.use },
        .{ "define_outer", a.define_outer }, .{ "hoist", a.hoist },             .{ "builtins", a.builtins },
        .{ "ordered", a.ordered },           .{ "namespace", a.namespace },     .{ "on_undefined", a.on_undefined },
        .{ "on_redefine", a.on_redefine },   .{ "on_unused", a.on_unused },     .{ "on_shadow", a.on_shadow },
        .{ "messages", a.messages },         .{ "codes", a.codes },             .{ "after", a.after },
        .{ "on_unresolved", a.on_unresolved }, .{ "members", a.members },             .{ "member_labels", a.member_labels },
        .{ "on_no_member", a.on_no_member },   .{ "imports", a.imports },             .{ "import_all", a.import_all },
        .{ "import_labels", a.import_labels }, .{ "exports", a.exports },             .{ "on_no_module", a.on_no_module },
        .{ "on_no_export", a.on_no_export },
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

// ============================================================================
// Compiled rules
// ============================================================================

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
    /// list[int]: the nodes that use it, and list[(start, end)]: their spans
    _uses: ?*PyObject = null,
    _use_spans: ?*PyObject = null,

    pub fn __del__(self: *Symbol) void {
        inline for (.{ "_name", "_namespace", "_uses", "_use_spans", "_origin", "_module" }) |field| {
            if (@field(self, field)) |obj| py.Py_DecRef(obj);
            @field(self, field) = null;
        }
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

/// What an Analysis keeps from a check: the names found by each scopes()
/// rule, in the arena the check ran in. Symbol objects are made on demand.
const AnalysisData = struct {
    arena: std.heap.ArenaAllocator,
    results: []const Rules.ScopeResult = &.{},
    /// Per result, per symbol: its Symbol object once created
    objects: []const []?*PyObject = &.{},
    /// The tree's nodes (owned by the Tree object the Analysis references)
    nodes: []const tree_mod.FlatNode = &.{},
    /// In a project: every file's key, by file index (strong references)
    keys: []const *PyObject = &.{},

    fn destroy(self: *AnalysisData) void {
        for (self.keys) |k| py.Py_DecRef(k);
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

    pub const __doc__: [*:0]const u8 = "The result of Rules.analyze(): diagnostics (in source order), tree, symbols (from scopes() rules), ok (no errors), resolve(node) and at(offset).";
    pub const resolve__doc__: [*:0]const u8 = "The Symbol that a node defines or uses, or None. `node` is a zgram Node, a node index, or an AST object built by zgram.";
    pub const resolve__params__ = "node";
    pub const at__doc__: [*:0]const u8 = "The Symbol defined or used at a byte offset of the source, or None.";
    pub const at__params__ = "offset";
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
        run.add(.{
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

    fn compileRule(state: *State, kind: Kind, args: *PyObject) ?CompiledRule {
        if (kind == .scopes) {
            const scope = compileScopes(state, args) orelse return null;
            return .{ .kind = kind, .message = "", .code = "", .severity = "error", .scope = scope };
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
                .scopes, .custom => "",
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
            .forbid, .scopes => {},
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
                        raise(py.PyExc_TypeError(), "rules[{d}] is not a spec (use inside(), unique(), forbid(), require(), count(), scopes() or custom())", .{i});
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
        /// Each key's text when it is a str, else ""
        key_texts: []const []const u8,
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
                for (self.keys, 0..) |k, i| {
                    const same = py.c.PyObject_RichCompareBool(k, key, py.c.Py_EQ);
                    if (same < 0) return error.PythonError;
                    if (same == 1) return @intCast(i);
                }
                return null;
            }
            var name = module;
            if (name.len >= 2 and (name[0] == '"' or name[0] == '\'') and name[name.len - 1] == name[0]) name = name[1 .. name.len - 1];
            for (self.key_texts, 0..) |k, i| {
                if (k.len != 0 and std.mem.eql(u8, k, name)) return @intCast(i);
            }
            return null;
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
        };

        /// What a scopes() rule matched in this file, kept between the two
        /// passes of a check (every file's exports, then the resolution)
        const ScopeInput = struct {
            rule: *const ScopeRule,
            scope_nodes: []const u32,
            defs: []const scopes_mod.Definition,
            uses: []const u32,
            members: []const scopes_mod.Member,
            imports: []const Import,
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

        fn add(self: *Run, finding: Finding) !void {
            var f = finding;
            f.order = @intCast(self.findings.items.len);
            try self.findings.append(self.arena, f);
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

        fn report(self: *Run, rule_idx: usize, node: u32, n: u32) !*Finding {
            const r = self.state.rules.items[rule_idx];
            const flat = self.tree.nodes[node];
            var v = self.values(node);
            v.count = n;
            v.min = r.min;
            v.max = r.max;
            try self.add(.{
                .start = flat.text_start,
                .end = flat.text_end,
                .severity = r.severity,
                .code = r.code,
                .message = try format(self.arena, r.message, v),
            });
            return &self.findings.items[self.findings.items.len - 1];
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
        fn matchAll(self: *Run, selectors: []const Selector) ![]u32 {
            // One selector that is just a name or a label: its candidates are the answer
            if (selectors.len == 1 and selectors[0].compounds.len == 1) {
                const only = selectors[0].compounds[0];
                const plain = only.attrs.len == 0 and only.nots.len == 0 and only.has.len == 0 and only.nth == 0 and !only.last;
                if (plain and (only.rules == null or only.field == 0)) return @constCast(try self.arena.dupe(u32, try self.candidates(only)));
            }
            var out: std.ArrayList(u32) = .empty;
            var in_order = true;
            for (selectors) |*s| {
                for (try self.candidates(s.compounds[s.compounds.len - 1])) |node| {
                    if (!s.matches(self.tree, node, null)) continue;
                    if (out.items.len != 0 and out.items[out.items.len - 1] >= node) in_order = false;
                    try out.append(self.arena, node);
                }
            }
            if (in_order) return out.items;
            std.sort.pdq(u32, out.items, {}, std.sort.asc(u32));
            var kept: usize = 0;
            for (out.items) |node| {
                if (kept == 0 or out.items[kept - 1] != node) {
                    out.items[kept] = node;
                    kept += 1;
                }
            }
            return out.items[0..kept];
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

            var defs: std.ArrayList(scopes_mod.Definition) = .empty;
            for (inner) |node| {
                // Listed in both: the outer form wins
                if (std.sort.binarySearch(u32, outer, node, orderU32) == null) try defs.append(self.arena, .{ .node = node });
            }
            for (outer) |node| try defs.append(self.arena, .{ .node = node, .outer = true });
            for (defs.items) |*d| {
                d.hoisted = std.sort.binarySearch(u32, hoisted, d.node, orderU32) != null;
                const parent = t.parents[d.node];
                const whole = parent != NONE and std.sort.binarySearch(u32, after, d.node, orderU32) != null;
                d.visible_from = t.nodes[if (whole) parent else d.node].text_end;
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

            std.sort.pdq(scopes_mod.Definition, defs.items, {}, struct {
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
                .defs = defs.items,
                .uses = kept_uses,
                .members = members.items,
                .imports = imports.items,
            };
            if (self.in_project and (sr.imports.len != 0 or sr.import_all.len != 0)) {
                // What the other files can import: the top-level definitions
                const top = try scopes_mod.analyze(self.arena, t, scope_nodes, defs.items, &.{}, &.{}, &.{}, &.{}, .{});
                for (top.symbols.items) |sym| {
                    if (!sym.exported or sym.node == NONE) continue;
                    if (sr.exports.len != 0 and !self.anyMatches(sr.exports, sym.node)) continue;
                    const entry = try input.exports.getOrPut(self.arena, sym.name);
                    if (!entry.found_existing) entry.value_ptr.* = sym.node;
                }
            }
            try self.scope_inputs.append(self.arena, input);
        }

        const FinishError = error{ OutOfMemory, PythonError };

        /// Second pass of a scopes() rule: resolve the imports against the
        /// other files' exports (`link`; null when checking one file alone),
        /// then resolve every name.
        fn finishScopes(self: *Run, index: usize, link: ?*const Link, file: usize) FinishError!void {
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
                // what a wildcard import brings in
                const target: ?u32 = if (link) |l| try l.resolve(file, module_text) else null;
                const other = target orelse {
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
                if (p.kind == .undefined and sr.on_unresolved != null) {
                    try self.unresolved.append(self.arena, .{ .rule = sr, .problem = p });
                } else try self.reportProblem(sr, p);
            }
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
            try self.add(finding);
        }

        fn orderU32(a: u32, b: u32) std.math.Order {
            return std.math.order(a, b);
        }

        fn check(self: *Run, rule_idx: usize) !void {
            const cr = &self.state.rules.items[rule_idx];
            if (cr.kind == .custom) return; // run afterwards, from Python
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
                        const finding = try self.report(rule_idx, m.node, 0);
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
                .scopes, .custom => unreachable,
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
    pub fn analyze(self: *Rules, source: *PyObject) pyoz.Signature(?*PyObject, "Analysis") {
        var out: [1]*PyObject = undefined;
        if (!self.analyzeFiles(&.{source}, null, null, &out)) return .{ .value = null };
        return .{ .value = out[0] };
    }

    /// Check a tree (a zgram Tree or Node, or source text to parse first)
    /// against the rules. Returns the diagnostics in source order.
    pub fn check(self: *Rules, source: *PyObject) pyoz.Signature(?*PyObject, "list[Diagnostic]") {
        var out: [1]*PyObject = undefined;
        if (!self.analyzeFiles(&.{source}, null, null, &out)) return .{ .value = null };
        defer py.Py_DecRef(out[0]);
        return .{ .value = py.c.PyObject_GetAttrString(out[0], "diagnostics") };
    }

    /// Check several files together: imports between them are resolved.
    /// `files` maps a key (usually a module name or a path) to a source.
    pub fn analyze_project(self: *Rules, args: pyoz.Args(struct { files: *PyObject, resolve: ?*PyObject = null })) pyoz.Signature(?*PyObject, "Project") {
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
        if (!self.analyzeFiles(sources[0..i], keys[0..i], resolver, out)) return .{ .value = null };
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

    /// Check `sources` together. `keys` names them (null: one file checked
    /// alone, whose imports can't be followed). On success `out` receives a
    /// new reference to each file's Analysis.
    fn analyzeFiles(self: *Rules, sources: []const *PyObject, keys: ?[]const *PyObject, resolver: ?*PyObject, out: []*PyObject) bool {
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
            files[opened] = self.openFile(state, source) orelse return false;
            files[opened].run.in_project = keys != null;
            opened += 1;
        }

        // Pass 1: the structural rules, and what each file defines and exports
        for (files) |f| {
            f.run.buildIndex() catch return oomObject() != null;
            for (0..state.rules.items.len) |i| f.run.check(i) catch return oomObject() != null;
        }

        // Pass 2: names, with the imports resolved against the other files
        const runs = allocator.alloc(*Run, files.len) catch return oomObject() != null;
        defer allocator.free(runs);
        const key_texts = allocator.alloc([]const u8, files.len) catch return oomObject() != null;
        defer allocator.free(key_texts);
        for (files, 0..) |f, i| {
            runs[i] = f.run;
            key_texts[i] = "";
            if (keys) |ks| {
                if (py.PyUnicode_Check(ks[i])) {
                    var len: py.Py_ssize_t = 0;
                    if (py.c.PyUnicode_AsUTF8AndSize(ks[i], &len)) |ptr| key_texts[i] = ptr[0..@intCast(len)] else py.c.PyErr_Clear();
                }
            }
        }
        const link = Link{ .runs = runs, .keys = keys orelse &.{}, .key_texts = key_texts, .resolver = resolver };
        for (files, 0..) |f, file_index| {
            for (0..f.run.scope_inputs.items.len) |index| {
                f.run.finishScopes(index, if (keys != null) &link else null, file_index) catch |e| switch (e) {
                    error.OutOfMemory => return oomObject() != null,
                    error.PythonError => return false,
                };
            }
        }

        // Pass 3: the parts that call into Python, and the diagnostics
        for (files) |f| {
            if (!finishFile(f, keys)) return false;
        }
        for (files, 0..) |f, i| out[i] = f.analysis_obj;
        done = true;
        return true;
    }

    /// Read a source's tree through its capsule and set up its run.
    fn openFile(self: *Rules, state: *State, source: *PyObject) ?File {
        // Text is parsed first; a Node stands for its Tree
        var tree_obj: *PyObject = undefined;
        if (py.PyUnicode_Check(source) or py.PyBytes_Check(source)) {
            tree_obj = py.c.PyObject_CallMethod(self._parser.?, "parse_tree", "O", source) orelse return null;
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

        done = true;
        return .{ .analysis_obj = analysis_obj, .analysis = analysis, .data = data, .run = run, .input = input };
    }

    fn oomFile() ?File {
        _ = py.c.PyErr_NoMemory();
        return null;
    }

    /// Last pass for one file: hand the names to its Analysis, run the rules
    /// written in Python, and turn the findings into Diagnostic objects.
    fn finishFile(f: File, keys: ?[]const *PyObject) bool {
        const run = f.run;
        const arena = run.arena;

        const objects = arena.alloc([]?*PyObject, run.scope_results.items.len) catch return oomObject() != null;
        for (objects, run.scope_results.items) |*slot, result| {
            slot.* = arena.alloc(?*PyObject, result.result.symbols.items.len) catch return oomObject() != null;
            @memset(slot.*, null);
        }
        f.data.results = run.scope_results.items;
        f.data.objects = objects;
        if (keys) |ks| {
            const kept = arena.dupe(*PyObject, ks) catch return oomObject() != null;
            for (kept) |k| py.Py_IncRef(k);
            f.data.keys = kept;
        }

        if (!runPython(run, f.analysis._tree.?, f.analysis_obj)) return false;

        std.sort.pdq(Finding, run.findings.items, {}, Finding.before);

        const zgram = py.c.PyImport_ImportModule("zgram") orelse return false;
        defer py.Py_DecRef(zgram);
        const cls = py.c.PyObject_GetAttrString(zgram, "Diagnostic") orelse return false;
        defer py.Py_DecRef(cls);

        const lines: []const u32 = if (run.findings.items.len == 0) &.{} else lineStarts(arena, f.input) catch return oomObject() != null;
        const list = py.c.PyList_New(@intCast(run.findings.items.len)) orelse return false;
        for (run.findings.items, 0..) |finding, i| {
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
            _ = py.c.PyList_SetItem(list, @intCast(i), d);
        }
        f.analysis._diagnostics = list;
        return true;
    }

    pub const __doc__: [*:0]const u8 = "Rules(parser, rules=None): rules compiled against a zgram parser's grammar. check(source) returns the zgram.Diagnostic of every violation, in source order; analyze(source) also returns the symbols found by scopes() rules.";
    pub const check__doc__: [*:0]const u8 = "Check a zgram Tree or Node (or source text, parsed first) against the rules. Returns a list of zgram.Diagnostic in source order.";
    pub const check__params__ = "source";
    pub const analyze__doc__: [*:0]const u8 = "Like check(), but returns an Analysis: diagnostics, tree, symbols, and resolve(node) / at(offset) to look names up.";
    pub const analyze__params__ = "source";
    pub const analyze_project__doc__: [*:0]const u8 = "Check several files together, resolving the imports between them. files is a dict of key -> source; resolve(module_text, importing_key) returns the key of the file a module name refers to, or None (default: the module's text, without quotes, is the key). Returns a Project.";
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
        pyoz.func("scopes", scopes, "scopes(scope, define, use, define_outer=None, hoist=None, after=None, builtins=None, ordered=True, namespace='name', on_undefined='error', on_redefine='error', on_unused='ignore', on_shadow='ignore', on_no_member='error', members=None, member_labels=('target', 'name'), imports=None, import_all=None, import_labels=('module', 'names', 'alias'), exports=None, on_no_module='error', on_no_export='error', on_unresolved=None, messages=None, codes=None): resolve names. `scope` nodes open a scope; `define` nodes define their text as a name in the scope around them (`define_outer`: in the scope outside that one); `use` nodes must resolve to a definition. `hoist` definitions are visible before their position; `after` definitions only once their parent node has ended. `members` nodes are accesses like a.b: the child labelled name is looked up in the scope that the child labelled target names."),
        pyoz.func("custom", custom, "custom(selector, function, code=None): call function(node, ctx) for every node matching `selector`."),
        pyoz.func("version", version, "Return the zrules version string"),
    },
    .classes = &.{
        pyoz.class("Rule", Rule),
        pyoz.class("Rules", Rules),
        pyoz.class("Analysis", Analysis),
        pyoz.class("Symbol", Symbol),
        pyoz.class("Context", Context),
        pyoz.class("Project", Project),
    },
});

// Required: forces analysis of all pub decls so PyInit_ is exported.
comptime {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        _ = @field(@This(), decl.name);
    }
}
