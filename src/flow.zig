//! Control flow: code that can't be reached, functions that may end without
//! returning, and variables used before they have a value.
//!
//! The caller matches the selectors; this works on the resulting node lists.
//! Control structures nest (a sequence of statements, a branch with its
//! arms, a loop with its body), so one walk over the tree follows every
//! path: the state at a point is whether it can be reached and which
//! variables have a value on every path (and on some path) that gets there.
//!
//! A variable is followed if it is declared without a value, or defined by
//! an assignment; the others have a value from their definition on. Only
//! uses in the function that declares the variable are judged: when a nested
//! function runs is not something the tree says.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree_mod = @import("tree.zig");
const scopes = @import("scopes.zig");
const Tree = tree_mod.Tree;
const NONE = tree_mod.NONE;

/// Control structures nested deeper than this are not looked into: the walk
/// recurses, and must not run out of stack on a pathological input.
pub const MAX_DEPTH = 256;

pub const ProblemKind = enum { dead, missing_return, unassigned, maybe_unassigned };

pub const Problem = struct {
    kind: ProblemKind,
    node: u32,
};

pub const Labels = struct {
    name: u8 = 0,
    value: u8 = 0,
    target: u8 = 0,
};

/// What the caller matched (node lists in source order)
pub const Inputs = struct {
    labels: Labels = .{},
    /// Nodes whose children run one after the other
    sequences: []const u32 = &.{},
    /// Nodes with a flow of their own, which does not run where it is written
    functions: []const u32 = &.{},
    /// Nodes that run one of their arms
    branches: []const u32 = &.{},
    /// The arms (none given: a branch's child sequences and branches)
    arms: []const u32 = &.{},
    /// Arms one of which always runs when no other does (`else`, `default`)
    otherwise: []const u32 = &.{},
    /// Nodes whose body (their first child sequence) runs any number of times
    loops: []const u32 = &.{},
    /// Loops that only end through a `break`
    forever: []const u32 = &.{},
    /// Loops whose body runs before their condition is looked at
    at_least_once: []const u32 = &.{},
    /// Nodes after which the function (or the program) does not go on
    exits: []const u32 = &.{},
    breaks: []const u32 = &.{},
    continues: []const u32 = &.{},
    /// Functions whose end must not be reachable
    must_return: []const u32 = &.{},

    /// For the variables: the names, and what the name resolution matched
    names: ?*const scopes.Result = null,
    uses: []const u32 = &.{},
    definitions: []const scopes.Definition = &.{},
    members: []const scopes.Member = &.{},
    /// Declarations: child `name`, optional child `value`
    variables: []const u32 = &.{},
    /// Assignments: child `target` (or `name`)
    assigns: []const u32 = &.{},
};

const Kind = enum(u8) { plain, sequence, function, branch, loop, exit, brk, cont };

const Flags = packed struct(u8) {
    arm: bool = false,
    otherwise: bool = false,
    forever: bool = false,
    once: bool = false,
    must_return: bool = false,
    /// Gives a followed variable its value (when `effect` is reached)
    assign: bool = false,
    _: u2 = 0,
};

const State = struct {
    live: bool,
    /// Per followed variable of the function: has a value on every path here
    all: []usize,
    /// ... on some path here
    some: []usize,
};

const Pending = struct { at: u32, bit: u32 };

const Loop = struct {
    breaks: State,
    continues: State,
};

const Flow = struct {
    /// Bitset words of a state in this function
    words: usize,
    loop: ?*Loop = null,
    /// Assignments whose statement hasn't ended yet
    pending: std.ArrayList(Pending) = .empty,
    /// Bitsets no longer in use
    spare: std.ArrayList([]usize) = .empty,
    /// Variables already reported (allocated at the first report)
    reported: []usize = &.{},
};

pub const Analysis = struct {
    arena: Allocator,
    tree: *const Tree,
    in: Inputs,
    problems: std.ArrayList(Problem) = .empty,

    kind: []Kind = &.{},
    flags: []Flags = &.{},
    /// Per node: the bit of the followed variable it uses or assigns, in the
    /// function that declares it; NONE otherwise
    bit: []u32 = &.{},
    /// Per assigning node: the node index at which the value is there
    effect: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Function node (NONE = the top level) -> its number of followed variables
    counts: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    arms_given: bool = false,
    depth: u32 = 0,

    const Error = Allocator.Error;

    pub fn run(self: *Analysis) Error!void {
        const t = self.tree;
        const n = t.nodes.len;
        if (n == 0) return;
        self.kind = try self.arena.alloc(Kind, n);
        @memset(self.kind, .plain);
        self.flags = try self.arena.alloc(Flags, n);
        @memset(self.flags, .{});

        // Later ones win: a node that is a loop and a sequence is a loop
        for (self.in.sequences) |node| self.kind[node] = .sequence;
        for (self.in.exits) |node| self.kind[node] = .exit;
        for (self.in.breaks) |node| self.kind[node] = .brk;
        for (self.in.continues) |node| self.kind[node] = .cont;
        for (self.in.branches) |node| self.kind[node] = .branch;
        for (self.in.loops) |node| self.kind[node] = .loop;
        for (self.in.forever) |node| {
            self.kind[node] = .loop;
            self.flags[node].forever = true;
        }
        for (self.in.at_least_once) |node| {
            self.kind[node] = .loop;
            self.flags[node].once = true;
        }
        for (self.in.functions) |node| self.kind[node] = .function;
        for (self.in.must_return) |node| self.flags[node].must_return = true;
        self.arms_given = self.in.arms.len != 0;
        for (self.in.arms) |node| self.flags[node].arm = true;
        for (self.in.otherwise) |node| {
            self.flags[node].arm = true;
            self.flags[node].otherwise = true;
        }

        try self.prepareVariables();

        var flow = Flow{ .words = self.wordsOf(NONE) };
        var state = try self.fresh(&flow, true);
        try self.walk(0, &state, &flow);
    }

    fn report(self: *Analysis, kind: ProblemKind, node: u32) Error!void {
        try self.problems.append(self.arena, .{ .kind = kind, .node = node });
    }

    fn child(self: *const Analysis, node: u32, field: u8) u32 {
        if (field == 0) return NONE;
        const t = self.tree;
        const stop = t.end(node);
        var c = node + 1;
        while (c < stop) : (c = t.end(c)) {
            if (t.nodes[c].fieldId() == field) return c;
        }
        return NONE;
    }

    // ── Which variables are followed, and where they are used and assigned ──

    fn prepareVariables(self: *Analysis) Error!void {
        const names = self.in.names orelse return;
        if (self.in.variables.len == 0 and self.in.assigns.len == 0) return;
        const t = self.tree;
        const n = t.nodes.len;
        const labels = self.in.labels;

        // The function each node is in (NONE = the top level)
        const function_of = try self.arena.alloc(u32, n);
        for (function_of, t.parents) |*slot, parent| {
            slot.* = if (parent == NONE) NONE else if (self.kind[parent] == .function) parent else function_of[parent];
        }

        self.bit = try self.arena.alloc(u32, n);
        @memset(self.bit, NONE);
        // Per symbol: its bit in the function that declares it
        const symbol_bit = try self.arena.alloc(u32, names.symbols.items.len);
        @memset(symbol_bit, NONE);

        // Followed: declared without a value, or defined by an assignment
        for (self.in.variables) |decl| {
            if (self.child(decl, labels.value) != NONE) continue;
            var it = self.labelled(decl, labels.name);
            var any = false;
            while (it.next()) |name| {
                any = true;
                try self.follow(names, symbol_bit, function_of, name);
            }
            if (!any) try self.follow(names, symbol_bit, function_of, decl);
        }
        // In `a.b`, neither the whole nor `b` is a variable
        const is_member = try self.arena.alloc(bool, n);
        @memset(is_member, false);
        for (self.in.members) |m| {
            is_member[m.node] = true;
            is_member[m.name] = true;
        }
        // The names given a value, each with the assignment it is in (`a, b = 1, 2` has two)
        const Target = struct { node: u32, assign: u32 };
        var targets: std.ArrayList(Target) = .empty;
        for (self.in.assigns) |node| {
            var it = self.labelled(node, labels.target);
            var any = false;
            while (it.next()) |written| {
                any = true;
                const target = self.targetOf(names, is_member, written);
                if (target != NONE) try targets.append(self.arena, .{ .node = target, .assign = node });
            }
            if (any) continue;
            const written = self.child(node, labels.name);
            const target = if (written != NONE) self.targetOf(names, is_member, written) else NONE;
            if (target != NONE) try targets.append(self.arena, .{ .node = target, .assign = node });
        }
        for (targets.items) |target| try self.follow(names, symbol_bit, function_of, target.node);
        // Given a value by another function than the one that declares it:
        // when that happens is not known, so it is not followed after all
        for (targets.items) |entry| {
            const target = entry.node;
            const sym = names.symbolOf(target).?;
            const symbol = names.symbols.items[sym];
            if (symbol.node == NONE or function_of[target] != function_of[symbol.node]) symbol_bit[sym] = NONE;
        }

        for (self.in.uses) |use| {
            if (is_member[use]) continue;
            const sym = names.symbolOf(use) orelse continue;
            const symbol = names.symbols.items[sym];
            if (symbol_bit[sym] == NONE or symbol.node == use or symbol.node == NONE) continue;
            if (function_of[use] != function_of[symbol.node]) continue;
            self.bit[use] = symbol_bit[sym];
        }
        // A node that defines a name (again) doesn't read it
        for (self.in.definitions) |d| self.bit[d.node] = NONE;

        for (targets.items) |entry| {
            const target = entry.node;
            const sym = names.symbolOf(target).?;
            if (symbol_bit[sym] == NONE) continue;
            self.bit[target] = symbol_bit[sym];
            self.flags[target].assign = true;
            try self.effect.put(self.arena, target, t.end(entry.assign));
        }
        // A declaration with a value (a second one, of a followed name) gives it
        for (self.in.variables) |decl| {
            if (self.child(decl, labels.value) == NONE) continue;
            var it = self.labelled(decl, labels.name);
            var any = false;
            while (it.next()) |name| {
                any = true;
                try self.gives(names, symbol_bit, function_of, name, t.end(decl));
            }
            if (!any) try self.gives(names, symbol_bit, function_of, decl, t.end(decl));
        }
    }

    /// The declaration of `name` gives it its value, from node index `at` on.
    fn gives(self: *Analysis, names: *const scopes.Result, symbol_bit: []const u32, function_of: []const u32, name: u32, at: u32) Error!void {
        const sym = names.symbolOf(name) orelse return;
        if (symbol_bit[sym] == NONE or function_of[name] != function_of[names.symbols.items[sym].node]) return;
        self.bit[name] = symbol_bit[sym];
        self.flags[name].assign = true;
        try self.effect.put(self.arena, name, at);
    }

    const Labelled = struct {
        tree: *const Tree,
        field: u8,
        at: u32,
        stop: u32,

        fn next(self: *Labelled) ?u32 {
            if (self.field == 0) return null;
            while (self.at < self.stop) {
                const c = self.at;
                self.at = self.tree.end(c);
                if (self.tree.nodes[c].fieldId() == self.field) return c;
            }
            return null;
        }
    };

    /// The children of `node` labelled `field`, in order.
    fn labelled(self: *const Analysis, node: u32, field: u8) Labelled {
        return .{ .tree = self.tree, .field = field, .at = node + 1, .stop = self.tree.end(node) };
    }

    /// The name that `written` (the target of an assignment) gives a value
    /// to: itself, through pass-through nodes, if that is a name and not `a.b` or `a[i]`.
    fn targetOf(self: *const Analysis, names: *const scopes.Result, is_member: []const bool, written: u32) u32 {
        const t = self.tree;
        var target = written;
        while (true) {
            if (names.symbolOf(target) != null) break;
            const inner = target + 1;
            if (inner >= t.end(target) or t.end(inner) != t.end(target)) return NONE;
            // A wrapper adds nothing to the text: `f()` is not `f`
            if (t.nodes[inner].text_start != t.nodes[target].text_start or t.nodes[inner].text_end != t.nodes[target].text_end) return NONE;
            target = inner;
        }
        return if (is_member[target]) NONE else target;
    }

    /// Follow the symbol defined at `name` (if that is where it is defined).
    fn follow(self: *Analysis, names: *const scopes.Result, symbol_bit: []u32, function_of: []const u32, name: u32) Error!void {
        const sym = names.symbolOf(name) orelse return;
        if (symbol_bit[sym] != NONE or names.symbols.items[sym].node != name) return;
        const entry = try self.counts.getOrPutValue(self.arena, function_of[name], 0);
        symbol_bit[sym] = entry.value_ptr.*;
        entry.value_ptr.* += 1;
    }

    fn wordsOf(self: *const Analysis, function: u32) usize {
        const count = self.counts.get(function) orelse 0;
        return (count + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);
    }

    // ── States ──

    /// A bitset of the function's size: one given back, or a new one.
    fn buffer(self: *Analysis, flow: *Flow) Error![]usize {
        return flow.spare.pop() orelse try self.arena.alloc(usize, flow.words);
    }

    fn fresh(self: *Analysis, flow: *Flow, live: bool) Error!State {
        const state = State{ .live = live, .all = try self.buffer(flow), .some = try self.buffer(flow) };
        @memset(state.all, 0);
        @memset(state.some, 0);
        return state;
    }

    fn copy(self: *Analysis, flow: *Flow, state: State) Error!State {
        const out = State{ .live = state.live, .all = try self.buffer(flow), .some = try self.buffer(flow) };
        @memcpy(out.all, state.all);
        @memcpy(out.some, state.some);
        return out;
    }

    /// A state no path continues from: its bitsets serve the next one, so
    /// the memory in use follows the nesting, not the number of branches.
    fn release(self: *Analysis, flow: *Flow, state: State) Error!void {
        try flow.spare.append(self.arena, state.all);
        try flow.spare.append(self.arena, state.some);
    }

    /// Two paths join: a variable has a value if it has one on both (a path
    /// that can't be taken doesn't count).
    fn meet(into: *State, from: State) void {
        for (into.some, from.some) |*a, b| a.* |= b;
        if (!from.live) return;
        if (into.live) {
            for (into.all, from.all) |*a, b| a.* &= b;
        } else {
            @memcpy(into.all, from.all);
            into.live = true;
        }
    }

    fn give(state: *State, bit: u32) void {
        const mask = @as(usize, 1) << @intCast(bit % @bitSizeOf(usize));
        state.all[bit / @bitSizeOf(usize)] |= mask;
        state.some[bit / @bitSizeOf(usize)] |= mask;
    }

    fn has(set: []const usize, bit: u32) bool {
        return set[bit / @bitSizeOf(usize)] & (@as(usize, 1) << @intCast(bit % @bitSizeOf(usize))) != 0;
    }

    /// Assignments whose statement ends at or before `at` have happened.
    fn settle(flow: *Flow, state: *State, at: u32) void {
        var i: usize = 0;
        while (i < flow.pending.items.len) {
            if (flow.pending.items[i].at > at) {
                i += 1;
                continue;
            }
            give(state, flow.pending.items[i].bit);
            _ = flow.pending.swapRemove(i);
        }
    }

    // ── The walk ──

    fn walk(self: *Analysis, node: u32, state: *State, flow: *Flow) Error!void {
        const kind = self.kind[node];
        if (kind == .plain) return self.scan(node, state, flow);
        if (self.depth >= MAX_DEPTH) return;
        self.depth += 1;
        defer self.depth -= 1;
        switch (kind) {
            .plain => unreachable,
            .function => try self.functionFlow(node),
            .sequence => try self.sequence(node, state, flow),
            .branch => try self.branch(node, state, flow),
            .loop => try self.loop(node, state, flow),
            .exit => {
                try self.scan(node, state, flow);
                state.live = false;
            },
            .brk => {
                try self.scan(node, state, flow);
                if (flow.loop) |l| meet(&l.breaks, state.*);
                state.live = false;
            },
            .cont => {
                try self.scan(node, state, flow);
                if (flow.loop) |l| meet(&l.continues, state.*);
                state.live = false;
            },
        }
    }

    /// A node that is no control structure: what is inside it happens in
    /// source order (and the control structures inside it are walked).
    fn scan(self: *Analysis, node: u32, state: *State, flow: *Flow) Error!void {
        const t = self.tree;
        const stop = t.end(node);
        try self.visit(node, state, flow);
        var i = node + 1;
        while (i < stop) {
            if (flow.pending.items.len != 0) settle(flow, state, i);
            if (self.kind[i] != .plain) {
                try self.walk(i, state, flow);
                i = t.end(i);
                continue;
            }
            try self.visit(i, state, flow);
            i += 1;
        }
        if (flow.pending.items.len != 0) settle(flow, state, stop);
    }

    /// One node: a use of a followed variable, or an assignment to one.
    fn visit(self: *Analysis, node: u32, state: *State, flow: *Flow) Error!void {
        if (self.bit.len == 0) return;
        const bit = self.bit[node];
        if (bit == NONE) return;
        if (self.flags[node].assign) {
            try flow.pending.append(self.arena, .{ .at = self.effect.get(node).?, .bit = bit });
            return;
        }
        if (!state.live or has(state.all, bit)) return;
        // Said once per variable, whatever the path
        if (flow.reported.len == 0) {
            flow.reported = try self.arena.alloc(usize, flow.words);
            @memset(flow.reported, 0);
        }
        if (has(flow.reported, bit)) return;
        flow.reported[bit / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(bit % @bitSizeOf(usize));
        try self.report(if (has(state.some, bit)) .maybe_unassigned else .unassigned, node);
    }

    fn sequence(self: *Analysis, node: u32, state: *State, flow: *Flow) Error!void {
        const t = self.tree;
        const stop = t.end(node);
        var reported = !state.live;
        var c = node + 1;
        while (c < stop) : (c = t.end(c)) {
            if (flow.pending.items.len != 0) settle(flow, state, c);
            // A function written after a `return` is still a definition
            if (!state.live and !reported and self.kind[c] != .function) {
                try self.report(.dead, c);
                reported = true;
            }
            try self.walk(c, state, flow);
        }
        if (flow.pending.items.len != 0) settle(flow, state, stop);
    }

    fn isArm(self: *const Analysis, node: u32) bool {
        if (self.kind[node] == .branch) return true; // `else if`
        if (self.arms_given) return self.flags[node].arm;
        return self.kind[node] == .sequence or self.flags[node].arm;
    }

    fn branch(self: *Analysis, node: u32, state: *State, flow: *Flow) Error!void {
        const t = self.tree;
        const stop = t.end(node);
        var out = try self.fresh(flow, false);
        var exhaustive = false;
        var c = node + 1;
        while (c < stop) : (c = t.end(c)) {
            if (flow.pending.items.len != 0) settle(flow, state, c);
            if (!self.isArm(c)) {
                // A condition: evaluated on the way to the arms after it
                try self.walk(c, state, flow);
                continue;
            }
            var arm = try self.copy(flow, state.*);
            try self.walk(c, &arm, flow);
            if (flow.pending.items.len != 0) settle(flow, &arm, t.end(c));
            meet(&out, arm);
            try self.release(flow, arm);
            // A nested branch stands for everything else: what it doesn't
            // cover is part of its own result
            if (self.flags[c].otherwise or self.kind[c] == .branch) exhaustive = true;
        }
        if (!exhaustive) meet(&out, state.*);
        try self.release(flow, state.*);
        state.* = out;
    }

    fn loop(self: *Analysis, node: u32, state: *State, flow: *Flow) Error!void {
        const t = self.tree;
        const stop = t.end(node);
        const flags = self.flags[node];
        var frame = Loop{ .breaks = try self.fresh(flow, false), .continues = try self.fresh(flow, false) };
        var before: ?State = null;
        var c = node + 1;
        while (c < stop) : (c = t.end(c)) {
            if (flow.pending.items.len != 0) settle(flow, state, c);
            if (before != null or self.kind[c] != .sequence) {
                // Before the body: the condition. After it: the step of a
                // `for`, the condition of a `do ... while`.
                try self.walk(c, state, flow);
                continue;
            }
            before = try self.copy(flow, state.*);
            const outer = flow.loop;
            flow.loop = &frame;
            try self.walk(c, state, flow);
            flow.loop = outer;
            if (flow.pending.items.len != 0) settle(flow, state, t.end(c));
            // The end of an iteration: the end of the body, or a `continue`
            meet(state, frame.continues);
        }
        defer {
            self.release(flow, frame.breaks) catch {};
            self.release(flow, frame.continues) catch {};
        }
        const skipped = before orelse return;
        var out = try self.fresh(flow, false);
        // What was given a value in the loop may have one afterwards
        for (out.some, state.some) |*a, b| a.* |= b;
        if (!flags.forever) meet(&out, if (flags.once) state.* else skipped);
        meet(&out, frame.breaks);
        try self.release(flow, skipped);
        try self.release(flow, state.*);
        state.* = out;
    }

    /// A function: a flow of its own, starting with nothing given a value.
    fn functionFlow(self: *Analysis, node: u32) Error!void {
        var flow = Flow{ .words = self.wordsOf(node) };
        var state = try self.fresh(&flow, true);
        try self.scan(node, &state, &flow);
        if (self.flags[node].must_return and state.live) {
            const name = self.child(node, self.in.labels.name);
            try self.report(.missing_return, if (name != NONE) name else node);
        }
    }
};
