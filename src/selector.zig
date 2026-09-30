//! Selectors: patterns over a parse tree, in the spirit of CSS.
//!
//!     call                 every node of rule `call` (or of a rule mapped to class `call`)
//!     *                    any node
//!     .cond                a node labelled `cond` in its parent
//!     If.then              both: that rule/class and that label
//!     call[name=len]       ... with a direct child labelled `name` whose text is `len`
//!     call > ident         an `ident` that is a direct child of a `call`
//!     funcdef ident        an `ident` anywhere inside a `funcdef`
//!     call:not(.value)     a `call` that is not labelled `value`
//!     call:has(> .args)    a `call` with a child labelled `args` (`:has(x)`: a descendant)
//!     .params:nth(2)       the second child labelled `params` of its parent
//!     .params:first  .params:last
//!     let + expr           an `expr` right after a `let` sibling (`let ~ expr`: anywhere after)
//!     break, return        either one (where a selector list is accepted)
//!
//! A name is a grammar rule name or the name of a `-> Class` action; a class
//! name stands for every rule mapped to it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const NONE = tree_mod.NONE;

/// The grammar's names, by id
pub const Names = struct {
    rules: []const []const u8,
    fields: []const []const u8,
    /// Per rule: its `-> name` action, or "" without one
    actions: []const []const u8,
};

pub const Attr = struct {
    /// Field id (index into Names.fields plus one)
    field: u8,
    value: []const u8,
};

/// `:has(...)`: something inside the node matches `sel`
pub const Has = struct {
    sel: Selector,
    /// `:has(> x)`: the match must hang directly from the node
    child: bool,
};

/// A selector has at most this many parts (so matches fit on the stack)
pub const MAX_COMPOUNDS = 16;

pub const Compound = struct {
    /// Per rule id: does the name accept it? null = any rule (`*` or no name)
    rules: ?[]const bool = null,
    /// Required field id; 0 = any
    field: u8 = 0,
    attrs: []const Attr = &.{},
    /// `:not(...)`: the node must match none of these
    nots: []const Compound = &.{},
    has: []const Has = &.{},
    /// `:nth(n)`: its position among the siblings this compound matches; 0 = any
    nth: u32 = 0,
    /// `:last`: no later sibling matches this compound
    last: bool = false,
    /// How it relates to the compound on its left
    relation: Relation = .first,
};

pub const Relation = enum {
    /// The leftmost compound: no relation
    first,
    /// `a > b`: b's parent
    child,
    /// `a b`: any ancestor of b
    descendant,
    /// `a + b`: the sibling just before b
    next,
    /// `a ~ b`: any sibling before b
    later,
};

pub const Error = error{ EmptySelector, UnknownName, UnknownField, BadSelector, OutOfMemory };

pub const Selector = struct {
    compounds: []const Compound,
    source: []const u8,

    /// Everything about a compound except its position among siblings.
    fn baseMatches(t: *const Tree, c: *const Compound, node: u32) bool {
        const n = t.nodes[node];
        if (c.rules) |rules| {
            if (n.ruleId() >= rules.len or !rules[n.ruleId()]) return false;
        }
        if (c.field != 0 and n.fieldId() != c.field) return false;
        const stop = t.end(node);
        for (c.attrs) |attr| {
            var found = false;
            var child = node + 1;
            while (child < stop) : (child = t.end(child)) {
                if (t.nodes[child].fieldId() == attr.field and std.mem.eql(u8, t.text(child), attr.value)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        for (c.nots) |*not| {
            if (baseMatches(t, not, node)) return false;
        }
        for (c.has) |h| {
            var chain: [MAX_COMPOUNDS]u32 = undefined;
            var found = false;
            var inner = node + 1;
            while (inner < stop and !found) : (inner += 1) {
                if (!h.sel.matches(t, inner, chain[0..h.sel.compounds.len])) continue;
                // The whole match must lie inside the node
                const top = chain[0];
                found = top > node and top < stop and (!h.child or t.parents[top] == node);
            }
            if (!found) return false;
        }
        return true;
    }

    fn compoundMatches(self: *const Selector, t: *const Tree, k: usize, node: u32) bool {
        const c = &self.compounds[k];
        if (!baseMatches(t, c, node)) return false;
        if (c.nth == 0 and !c.last) return true;
        const parent = t.parents[node];
        if (parent == NONE) return c.nth <= 1;
        var position: u32 = 0;
        var seen_self = false;
        const stop = t.end(parent);
        var sibling = parent + 1;
        while (sibling < stop) : (sibling = t.end(sibling)) {
            if (sibling == node) {
                position += 1;
                seen_self = true;
                if (c.nth != 0 and position != c.nth) return false;
                if (!c.last) return true;
            } else if (baseMatches(t, c, sibling)) {
                if (seen_self) return false; // a later match: not the last
                position += 1;
            }
        }
        return true;
    }

    fn matchFrom(self: *const Selector, t: *const Tree, k: usize, node: u32, chain: ?[]u32) bool {
        if (!self.compoundMatches(t, k, node)) return false;
        if (chain) |c| c[k] = node;
        if (k == 0) return true;
        var parent = t.parents[node];
        switch (self.compounds[k].relation) {
            .first => return true,
            .child => return parent != NONE and self.matchFrom(t, k - 1, parent, chain),
            .descendant => {
                while (parent != NONE) : (parent = t.parents[parent]) {
                    if (self.matchFrom(t, k - 1, parent, chain)) return true;
                }
                return false;
            },
            .next, .later => {
                if (parent == NONE) return false;
                // The siblings before `node`, nearest last
                var previous: u32 = NONE;
                var sibling = parent + 1;
                while (sibling < node) : (sibling = t.end(sibling)) {
                    if (self.compounds[k].relation == .later and self.matchFrom(t, k - 1, sibling, chain)) return true;
                    previous = sibling;
                }
                if (self.compounds[k].relation == .later or previous == NONE) return false;
                return self.matchFrom(t, k - 1, previous, chain);
            },
        }
    }

    /// Does `node` match? If so and `chain` is given (one slot per
    /// compound), it receives the node each compound matched: chain[0] is
    /// the outermost, the last is `node`.
    pub fn matches(self: *const Selector, t: *const Tree, node: u32, chain: ?[]u32) bool {
        return self.matchFrom(t, self.compounds.len - 1, node, chain);
    }

    /// Does `node` match the first compound alone (the selector's anchor)?
    pub fn anchorMatches(self: *const Selector, t: *const Tree, node: u32) bool {
        return self.compoundMatches(t, 0, node);
    }

    /// The selector without its last compound (for `require`).
    pub fn prefix(self: *const Selector) Selector {
        return .{ .compounds = self.compounds[0 .. self.compounds.len - 1], .source = self.source };
    }
};

fn isNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

const Parser = struct {
    arena: Allocator,
    names: Names,
    text: []const u8,
    pos: usize = 0,
    /// The name an UnknownName / UnknownField error is about
    bad_name: []const u8 = "",

    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }

    fn name(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.pos < self.text.len and isNameChar(self.text[self.pos])) self.pos += 1;
        return self.text[start..self.pos];
    }

    fn fieldId(self: *Parser, field: []const u8) Error!u8 {
        for (self.names.fields, 1..) |f, id| {
            if (std.mem.eql(u8, f, field)) return @intCast(id);
        }
        self.bad_name = field;
        return error.UnknownField;
    }

    fn compound(self: *Parser) Error!Compound {
        var c = Compound{};
        const start = self.pos;
        if (self.pos < self.text.len and self.text[self.pos] == '*') {
            self.pos += 1;
        } else {
            const n = self.name();
            if (n.len != 0) {
                const accepted = try self.arena.alloc(bool, self.names.rules.len);
                var any = false;
                for (accepted, self.names.rules, self.names.actions) |*a, rule, action| {
                    a.* = std.mem.eql(u8, rule, n) or std.mem.eql(u8, action, n);
                    any = any or a.*;
                }
                if (!any) {
                    self.bad_name = n;
                    return error.UnknownName;
                }
                c.rules = accepted;
            }
        }
        if (self.pos < self.text.len and self.text[self.pos] == '.') {
            self.pos += 1;
            const f = self.name();
            if (f.len == 0) return error.BadSelector;
            c.field = try self.fieldId(f);
        }
        var attrs: std.ArrayList(Attr) = .empty;
        var nots: std.ArrayList(Compound) = .empty;
        var has: std.ArrayList(Has) = .empty;
        while (self.pos < self.text.len and (self.text[self.pos] == '[' or self.text[self.pos] == ':')) {
            if (self.text[self.pos] == ':') {
                self.pos += 1;
                const pseudo = self.name();
                if (std.mem.eql(u8, pseudo, "first")) {
                    c.nth = 1;
                } else if (std.mem.eql(u8, pseudo, "last")) {
                    c.last = true;
                } else if (std.mem.eql(u8, pseudo, "nth")) {
                    const arg = std.mem.trim(u8, try self.parenthesized(), " \t");
                    c.nth = std.fmt.parseInt(u32, arg, 10) catch return error.BadSelector;
                    if (c.nth == 0) return error.BadSelector;
                } else if (std.mem.eql(u8, pseudo, "not")) {
                    var inner = Parser{ .arena = self.arena, .names = self.names, .text = std.mem.trim(u8, try self.parenthesized(), " \t") };
                    const not = inner.compound() catch |e| {
                        self.bad_name = inner.bad_name;
                        return e;
                    };
                    if (inner.pos != inner.text.len) return error.BadSelector;
                    try nots.append(self.arena, not);
                } else if (std.mem.eql(u8, pseudo, "has")) {
                    var arg = std.mem.trim(u8, try self.parenthesized(), " \t");
                    const child = arg.len != 0 and arg[0] == '>';
                    if (child) arg = arg[1..];
                    var inner = Parser{ .arena = self.arena, .names = self.names, .text = arg };
                    const sel = inner.selector() catch |e| {
                        self.bad_name = inner.bad_name;
                        return if (e == error.EmptySelector) error.BadSelector else e;
                    };
                    try has.append(self.arena, .{ .sel = sel, .child = child });
                } else return error.BadSelector;
                continue;
            }
            self.pos += 1;
            self.skipSpaces();
            const f = self.name();
            self.skipSpaces();
            if (f.len == 0 or self.pos >= self.text.len or self.text[self.pos] != '=') return error.BadSelector;
            self.pos += 1;
            const close = std.mem.indexOfScalarPos(u8, self.text, self.pos, ']') orelse return error.BadSelector;
            var value = std.mem.trim(u8, self.text[self.pos..close], " \t");
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) value = value[1 .. value.len - 1];
            self.pos = close + 1;
            try attrs.append(self.arena, .{ .field = try self.fieldId(f), .value = try self.arena.dupe(u8, value) });
        }
        c.attrs = attrs.items;
        c.nots = nots.items;
        c.has = has.items;
        if (self.pos == start) return error.BadSelector;
        return c;
    }

    /// The text between the `(` at the cursor and its matching `)`.
    fn parenthesized(self: *Parser) Error![]const u8 {
        if (self.pos >= self.text.len or self.text[self.pos] != '(') return error.BadSelector;
        const start = self.pos + 1;
        var depth: usize = 0;
        var in_brackets = false;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const ch = self.text[self.pos];
            if (in_brackets) {
                in_brackets = ch != ']';
            } else if (ch == '[') {
                in_brackets = true;
            } else if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    self.pos += 1;
                    return self.text[start .. self.pos - 1];
                }
            }
        }
        return error.BadSelector;
    }

    fn selector(self: *Parser) Error!Selector {
        var compounds: std.ArrayList(Compound) = .empty;
        self.skipSpaces();
        if (self.pos == self.text.len) return error.EmptySelector;
        try compounds.append(self.arena, try self.compound());
        while (true) {
            const before = self.pos;
            self.skipSpaces();
            if (self.pos == self.text.len) break;
            var relation: Relation = .descendant;
            const combinator = self.text[self.pos];
            if (combinator == '>' or combinator == '+' or combinator == '~') {
                relation = switch (combinator) {
                    '>' => .child,
                    '+' => .next,
                    else => .later,
                };
                self.pos += 1;
                self.skipSpaces();
            } else if (self.pos == before) {
                // Two compounds with nothing between them
                return error.BadSelector;
            }
            var c = try self.compound();
            c.relation = relation;
            try compounds.append(self.arena, c);
            if (compounds.items.len > MAX_COMPOUNDS) return error.BadSelector;
        }
        return .{ .compounds = compounds.items, .source = try self.arena.dupe(u8, self.text) };
    }
};

/// Compile `text` against the grammar's names. Everything is allocated in
/// `arena`. On UnknownName / UnknownField, `bad_name` receives the name.
pub fn compile(arena: Allocator, names: Names, text: []const u8, bad_name: *[]const u8) Error!Selector {
    var p = Parser{ .arena = arena, .names = names, .text = text };
    return p.selector() catch |e| {
        bad_name.* = p.bad_name;
        return e;
    };
}

/// Compile a comma-separated list of selectors (`break, return`): the
/// alternatives, in order. Commas inside `[...]` and `(...)` don't split.
pub fn compileList(arena: Allocator, names: Names, text: []const u8, bad_name: *[]const u8) Error![]Selector {
    var out: std.ArrayList(Selector) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i < text.len) {
            switch (text[i]) {
                '[', '(' => depth += 1,
                ']', ')' => depth -|= 1,
                else => {},
            }
            if (text[i] != ',' or depth != 0) continue;
        }
        try out.append(arena, try compile(arena, names, text[start..i], bad_name));
        start = i + 1;
    }
    return out.items;
}
