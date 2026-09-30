//! Scopes and names: which definition each use of a name refers to.
//!
//! The caller matches the selectors; this works on the resulting node lists.
//! A scope is a node; a definition belongs to the nearest scope above its
//! node (or, for an "outer" definition such as a function's own name, to the
//! scope above that one). A use is resolved through the scopes above it,
//! innermost first.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const NONE = tree_mod.NONE;

pub const Definition = struct {
    node: u32,
    /// Defined in the scope outside the one its node is in
    outer: bool = false,
    /// Visible before its position (functions that may be called before they appear)
    hoisted: bool = false,
    /// Offset from which uses in the same scope see it: the end of its
    /// name, or of its whole declaration (`let a = a;` must not see itself)
    visible_from: u32 = 0,
};

pub const Symbol = struct {
    name: []const u8,
    /// Defining node; NONE for a builtin
    node: u32,
    /// Scope node it is defined in; NONE = the global scope
    scope: u32,
    hoisted: bool,
    visible_from: u32 = 0,
    /// Nodes that use it, in source order
    uses: []const u32 = &.{},
};

pub const ProblemKind = enum { undefined, redefined, unused, shadowed };

pub const Problem = struct {
    kind: ProblemKind,
    node: u32,
    /// redefined / shadowed: the earlier definition's node (NONE for a builtin)
    other: u32 = NONE,
};

pub const Options = struct {
    /// A definition is visible only after its position to uses in its own
    /// scope; hoisted ones, and uses from nested scopes, always see it
    ordered: bool = true,
    report_unused: bool = false,
    report_shadowed: bool = false,
};

pub const Result = struct {
    symbols: []Symbol,
    problems: []Problem,
    /// Per node: the index into symbols of the name it defines or uses, or NONE
    by_node: []const u32,

    pub fn symbolOf(self: *const Result, node: u64) ?u32 {
        if (node >= self.by_node.len or self.by_node[node] == NONE) return null;
        return self.by_node[node];
    }
};

/// (scope, name id): names are interned once, so the table hashes two ints
fn key(scope: u32, name: u32) u64 {
    return (@as(u64, scope) << 32) | name;
}

/// `scopes`, `definitions` and `uses` hold node indices in source order.
pub fn analyze(
    arena: Allocator,
    t: *const Tree,
    scopes: []const u32,
    definitions: []const Definition,
    uses: []const u32,
    builtins: []const []const u8,
    options: Options,
) !Result {
    const n_nodes = t.nodes.len;

    // Nearest scope strictly above each node (NONE = global). Parents come
    // before their children, so one forward pass does it.
    const above = try arena.alloc(u32, n_nodes);
    {
        const is_scope = try arena.alloc(bool, n_nodes);
        @memset(is_scope, false);
        for (scopes) |s| is_scope[s] = true;
        for (above, t.parents) |*slot, parent| {
            slot.* = if (parent == NONE) NONE else if (is_scope[parent]) parent else above[parent];
        }
    }

    var names: std.StringHashMapUnmanaged(u32) = .empty;
    try names.ensureTotalCapacity(arena, @intCast(@min(definitions.len + builtins.len, std.math.maxInt(u32) / 2)));
    var symbols: std.ArrayList(Symbol) = .empty;
    try symbols.ensureTotalCapacity(arena, definitions.len + builtins.len);
    var problems: std.ArrayList(Problem) = .empty;
    var table: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    try table.ensureTotalCapacity(arena, @intCast(@min(definitions.len + builtins.len, std.math.maxInt(u32) / 2)));
    const by_node = try arena.alloc(u32, n_nodes);
    @memset(by_node, NONE);
    // A node that defines a name is not also a use of it
    const is_definition = try arena.alloc(bool, n_nodes);
    @memset(is_definition, false);
    for (definitions) |d| is_definition[d.node] = true;

    for (builtins) |name| {
        const id = try names.getOrPutValue(arena, name, names.count());
        const entry = try table.getOrPut(arena, key(NONE, id.value_ptr.*));
        if (entry.found_existing) continue;
        entry.value_ptr.* = @intCast(symbols.items.len);
        try symbols.append(arena, .{ .name = name, .node = NONE, .scope = NONE, .hoisted = true });
    }

    for (definitions) |d| {
        var scope = above[d.node];
        if (d.outer and scope != NONE) scope = above[scope];
        const name = t.text(d.node);
        const id = (try names.getOrPutValue(arena, name, names.count())).value_ptr.*;
        const entry = try table.getOrPut(arena, key(scope, id));
        if (entry.found_existing) {
            // Same name, same scope: the first definition stays the symbol
            try problems.append(arena, .{ .kind = .redefined, .node = d.node, .other = symbols.items[entry.value_ptr.*].node });
            by_node[d.node] = entry.value_ptr.*;
            continue;
        }
        entry.value_ptr.* = @intCast(symbols.items.len);
        by_node[d.node] = entry.value_ptr.*;
        try symbols.append(arena, .{ .name = name, .node = d.node, .scope = scope, .hoisted = d.hoisted, .visible_from = d.visible_from });
        if (options.report_shadowed) {
            var outer_scope = scope;
            while (outer_scope != NONE) {
                outer_scope = above[outer_scope];
                if (table.get(key(outer_scope, id))) |shadowed| {
                    try problems.append(arena, .{ .kind = .shadowed, .node = d.node, .other = symbols.items[shadowed].node });
                    break;
                }
            }
        }
    }

    // Resolve the uses, counting them per symbol
    const use_count = try arena.alloc(u32, symbols.items.len + 1);
    @memset(use_count, 0);
    var resolved: usize = 0;
    for (uses) |use| {
        if (is_definition[use]) continue;
        const id = names.get(t.text(use)) orelse {
            try problems.append(arena, .{ .kind = .undefined, .node = use });
            continue;
        };
        const own_scope = above[use];
        var scope = own_scope;
        const found: ?u32 = while (true) {
            if (table.get(key(scope, id))) |index| {
                const sym = symbols.items[index];
                const visible = !options.ordered or sym.hoisted or sym.node == NONE or scope != own_scope or
                    sym.visible_from <= t.nodes[use].text_start;
                if (visible) break index;
            }
            if (scope == NONE) break null;
            scope = above[scope];
        };
        if (found) |index| {
            by_node[use] = index;
            use_count[index + 1] += 1;
            resolved += 1;
        } else {
            try problems.append(arena, .{ .kind = .undefined, .node = use });
        }
    }

    // Group the uses by symbol: one array, each symbol a slice of it
    for (1..use_count.len) |i| use_count[i] += use_count[i - 1];
    const all_uses = try arena.alloc(u32, resolved);
    const next = try arena.dupe(u32, use_count[0..symbols.items.len]);
    for (uses) |use| {
        const index = by_node[use];
        if (index == NONE or is_definition[use]) continue;
        all_uses[next[index]] = use;
        next[index] += 1;
    }
    for (symbols.items, 0..) |*sym, i| sym.uses = all_uses[use_count[i]..use_count[i + 1]];

    if (options.report_unused) {
        for (symbols.items) |sym| {
            if (sym.node != NONE and sym.uses.len == 0) try problems.append(arena, .{ .kind = .unused, .node = sym.node });
        }
    }

    return .{ .symbols = symbols.items, .problems = problems.items, .by_node = by_node };
}
