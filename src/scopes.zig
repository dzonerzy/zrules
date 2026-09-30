//! Scopes and names: which definition each use of a name refers to.
//!
//! The caller matches the selectors; this works on the resulting node lists.
//! A scope is a node; a definition belongs to the nearest scope above its
//! node (or, for an "outer" definition such as a function's own name, to the
//! scope above that one). A use is resolved through the scopes above it,
//! innermost first.
//!
//! A member access `target.name` is resolved in the scope its target names:
//! an outer definition (a function's, an enum's, a module's own name) owns
//! the scope its node sits in, and `name` is looked up among that scope's
//! own definitions.

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
    /// The scope node this name stands for (an outer definition names the
    /// scope its node is in); NONE if it has no members
    owns: u32 = NONE,
    /// Defined at the top level of its file: other files can import it
    exported: bool = false,
    /// Where it really comes from, for a name imported from another file:
    /// that file's index and the defining node there; NONE otherwise
    origin_file: u32 = NONE,
    origin_node: u32 = NONE,
    /// For the local name of an imported module: that file's index
    module: u32 = NONE,
    /// Nodes that use it, in source order
    uses: []const u32 = &.{},
};

/// A name another file defines, made visible in this one (`from m import *`)
pub const External = struct {
    name: []const u8,
    file: u32,
    node: u32,
};

/// `target.name`: the access node and its two labelled children
pub const Member = struct {
    node: u32,
    target: u32,
    name: u32,
};

pub const ProblemKind = enum { undefined, redefined, unused, shadowed, no_member, no_module, no_export };

pub const Problem = struct {
    kind: ProblemKind,
    node: u32,
    /// redefined / shadowed: the earlier definition's node (NONE for a builtin).
    /// no_member: the node defining the name that lacks the member.
    other: u32 = NONE,
    /// no_member / no_export: the name of what lacks it, when `other` can't say
    owner: []const u8 = "",
};

pub const Options = struct {
    /// A definition is visible only after its position to uses in its own
    /// scope; hoisted ones, and uses from nested scopes, always see it
    ordered: bool = true,
    report_unused: bool = false,
    report_shadowed: bool = false,
    /// Names may come from somewhere this analysis can't see (a wildcard
    /// import of a file that isn't available): don't report undefined ones
    assume_defined: bool = false,
    /// Nodes evaluated in the scope outside the one they are written in (the
    /// bounds of a `for`, a parameter's default value): names in them are
    /// looked up from there
    outside: []const u32 = &.{},
};

pub const Result = struct {
    symbols: std.ArrayList(Symbol),
    problems: std.ArrayList(Problem),
    /// Per node: the index into symbols of the name it defines or uses, or NONE
    by_node: []u32,
    /// Member accesses whose target has no members known here (the caller
    /// may know better: the target may be an imported module)
    open_members: []const Member = &.{},
    /// Name -> id, and (scope, name id) -> symbol: what `lookup` reads
    names: std.StringHashMapUnmanaged(u32) = .empty,
    table: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Per node: the nearest scope strictly above it (NONE = global); the
    /// scope nodes (sorted); whether definitions are ordered. What
    /// `visibleAt` reads.
    above: []const u32 = &.{},
    scopes: []const u32 = &.{},
    ordered: bool = true,

    /// The symbols visible at byte offset `at` of the tree: those of the
    /// innermost scope around it and of every scope outside that one, an
    /// inner name hiding an outer one, in that order (innermost scope
    /// first), builtins and imported names last. In the innermost scope,
    /// with ordered definitions, only those visible from `at` on (or hoisted).
    pub fn visibleAt(self: *const Result, arena: Allocator, t: *const Tree, at: u32) ![]const u32 {
        // The innermost node around the offset, and the scope it is in
        var node: u32 = NONE;
        if (t.nodes.len != 0 and t.nodes[0].text_start <= at and at <= t.nodes[0].text_end) {
            node = 0;
            descend: while (true) {
                const stop = t.end(node);
                var child = node + 1;
                while (child < stop) : (child = t.end(child)) {
                    if (t.nodes[child].text_start <= at and at < t.nodes[child].text_end) {
                        node = child;
                        continue :descend;
                    }
                }
                break;
            }
        }
        const own_scope: u32 = if (node == NONE) NONE else if (std.sort.binarySearch(u32, self.scopes, node, orderU32) != null) node else self.above[node];

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var out: std.ArrayList(u32) = .empty;
        var scope = own_scope;
        while (true) {
            for (self.symbols.items, 0..) |sym, i| {
                if (sym.scope != scope) continue;
                const visible = !self.ordered or sym.hoisted or sym.node == NONE or scope != own_scope or sym.visible_from <= at;
                if (!visible) continue;
                const entry = try seen.getOrPut(arena, sym.name);
                if (entry.found_existing) continue;
                try out.append(arena, @intCast(i));
            }
            if (scope == NONE) break;
            scope = self.above[scope];
        }
        return out.items;
    }

    fn orderU32(a: u32, b: u32) std.math.Order {
        return std.math.order(a, b);
    }

    pub fn symbolOf(self: *const Result, node: u64) ?u32 {
        if (node >= self.by_node.len or self.by_node[node] == NONE) return null;
        return self.by_node[node];
    }

    /// The symbol `name` defined directly in `scope` (NONE = global), if any.
    pub fn lookup(self: *const Result, scope: u32, name: []const u8) ?u32 {
        const id = self.names.get(name) orelse return null;
        return self.table.get(key(scope, id));
    }
};

const NodeFlags = packed struct(u8) {
    /// Opens a scope
    scope: bool = false,
    /// Belongs to the scope outside the one it is written in (`outside`)
    lifted: bool = false,
    definition: bool = false,
    member_name: bool = false,
    /// A use that resolved (grouped by symbol at the end)
    resolved_use: bool = false,
    _: u3 = 0,
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
    members: []const Member,
    builtins: []const []const u8,
    externals: []const External,
    options: Options,
) !Result {
    const n_nodes = t.nodes.len;

    // What each node is, in one byte per node (one allocation to clear, not five)
    const flags = try arena.alloc(NodeFlags, n_nodes);
    @memset(flags, .{});
    for (scopes) |s| flags[s].scope = true;
    // An `outside` node, and what is in it, belongs to the scope outside
    // the one it is written in (its descendants inherit that)
    for (options.outside) |s| flags[s].lifted = true;
    // A node that defines a name is not also a use of it
    for (definitions) |d| flags[d.node].definition = true;
    // The name of a member access is looked up in its target's scope, not
    // through the scopes around it
    for (members) |m| flags[m.name].member_name = true;

    // Nearest scope strictly above each node (NONE = global). Parents come
    // before their children, so one forward pass does it.
    const above = try arena.alloc(u32, n_nodes);
    for (above, t.parents, flags) |*slot, parent, f| {
        slot.* = if (parent == NONE) NONE else if (flags[parent].scope) parent else above[parent];
        if (f.lifted and slot.* != NONE) slot.* = above[slot.*];
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

    for (builtins) |name| {
        const id = try names.getOrPutValue(arena, name, names.count());
        const entry = try table.getOrPut(arena, key(NONE, id.value_ptr.*));
        if (entry.found_existing) continue;
        entry.value_ptr.* = @intCast(symbols.items.len);
        try symbols.append(arena, .{ .name = name, .node = NONE, .scope = NONE, .hoisted = true });
    }
    try symbols.ensureUnusedCapacity(arena, externals.len);
    for (externals) |ext| {
        const id = try names.getOrPutValue(arena, ext.name, names.count());
        const entry = try table.getOrPut(arena, key(NONE, id.value_ptr.*));
        if (entry.found_existing) continue; // the first import of a name wins
        entry.value_ptr.* = @intCast(symbols.items.len);
        try symbols.append(arena, .{ .name = ext.name, .node = NONE, .scope = NONE, .hoisted = true, .origin_file = ext.file, .origin_node = ext.node });
    }

    for (definitions) |d| {
        var scope = above[d.node];
        // An outer definition names the scope its node is in
        const owns = if (d.outer) scope else NONE;
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
        try symbols.append(arena, .{
            .name = name,
            .node = d.node,
            .scope = scope,
            .hoisted = d.hoisted,
            .visible_from = d.visible_from,
            .owns = owns,
            .exported = scope == NONE or above[scope] == NONE,
        });
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
        if (flags[use].definition or flags[use].member_name) continue;
        const id = names.get(t.text(use)) orelse {
            if (!options.assume_defined) try problems.append(arena, .{ .kind = .undefined, .node = use });
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
            flags[use].resolved_use = true;
            use_count[index + 1] += 1;
            resolved += 1;
        } else if (!options.assume_defined) {
            try problems.append(arena, .{ .kind = .undefined, .node = use });
        }
    }

    // Member accesses, innermost first (in `a.b.c` the node for `a.b` comes
    // after the node for the whole, so go backwards)
    var open_members: std.ArrayList(Member) = .empty;
    var mi = members.len;
    while (mi > 0) {
        mi -= 1;
        const m = members[mi];
        const target = by_node[m.target];
        if (target == NONE) continue; // unknown or already reported
        const owner = symbols.items[target];
        // Not something with members known here (a variable, say): not ours to judge
        if (owner.owns == NONE) {
            try open_members.append(arena, m);
            continue;
        }
        const found: ?u32 = if (names.get(t.text(m.name))) |id| table.get(key(owner.owns, id)) else null;
        if (found) |index| {
            by_node[m.name] = index;
            by_node[m.node] = index;
            if (!flags[m.name].definition) {
                flags[m.name].resolved_use = true;
                use_count[index + 1] += 1;
                resolved += 1;
            }
        } else {
            try problems.append(arena, .{ .kind = .no_member, .node = m.name, .other = owner.node });
        }
    }

    // Group the uses by symbol: one array, each symbol a slice of it
    for (1..use_count.len) |i| use_count[i] += use_count[i - 1];
    const all_uses = try arena.alloc(u32, resolved);
    const next = try arena.dupe(u32, use_count[0..symbols.items.len]);
    for (flags, 0..) |f, node| {
        if (!f.resolved_use) continue;
        const index = by_node[node];
        all_uses[next[index]] = @intCast(node);
        next[index] += 1;
    }
    for (symbols.items, 0..) |*sym, i| sym.uses = all_uses[use_count[i]..use_count[i + 1]];

    if (options.report_unused) {
        for (symbols.items) |sym| {
            if (sym.node != NONE and sym.uses.len == 0) try problems.append(arena, .{ .kind = .unused, .node = sym.node });
        }
    }

    return .{
        .symbols = symbols,
        .problems = problems,
        .by_node = by_node,
        .open_members = open_members.items,
        .names = names,
        .table = table,
        .above = above,
        .scopes = scopes,
        .ordered = options.ordered,
    };
}
