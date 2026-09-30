"""examples/lua: a real language (Lua 5.4) checked end to end."""

import glob
import os
import sys

import pytest
import zgram

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples", "lua"))
import lua  # noqa: E402


def found(source):
    return [(d.line, d.severity, d.code) for d in lua.check(source)]


def codes(source):
    return [d.code for d in lua.check(source)]


VALID = r"""#!/usr/bin/lua
-- every kind of statement and expression
local a <const>, b <close> = 1, nil
local t = { 1, 2; x = 3, ["y"] = 4, f = function(...) return ... end, }
local s = 'single \' quote' .. "double \" quote" .. [[long
string]] .. [==[ with ]] inside ]==] .. "cont\z
             inued"
local n = 0xFF + 0x1p4 + 1e10 + .5 + 3. + 1 // 2 % 3 ^ -2 ^ 2
local bits = ~n & 0xF | 1 << 2 >> 1 ~ 3
--[[ a long
comment ]] --[==[ another ]==]
function t.g(x, ...) local y = x or select('#', ...) return y end
function t:m() return self end
local function fact(k) if k <= 1 then return 1 else return k * fact(k - 1) end end
for i = 1, #t, 1 do print(i) end
for k, v in pairs(t) do print(k, v) end
while n > 0 do n = n - 1 if n == 5 then break end end
repeat local done = n == 0 until done
do goto skip; ::skip:: end
if not a then print(b) elseif a == 1 then print(s) else print(bits) end
print(t.g(1), t:m(), fact(3), (t.g)(2), t.f"x", t.f{1}, #s, -n, not a, a ~= b)
t.x, t["y"] = t["y"], t.x
return t
"""


def test_valid_program_has_no_errors():
    assert [d for d in lua.check(VALID) if d.severity == "error"] == []
    assert codes(VALID) == []


@pytest.mark.parametrize(
    "source, expected",
    [
        ("break", ["break-outside-loop"]),
        ("while true do local f = function() break end end", ["break-outside-loop", "unused"]),
        ("local function f() return ... end f()", ["vararg-outside-vararg-function"]),
        ("local function f(...) return function() return ... end end f()", ["vararg-outside-vararg-function"]),
        ("print(...)", []),
        ("local function f(a, a) return a end f()", ["duplicate-parameter"]),
        ("::top:: ::top::", ["duplicate-label"]),
        ("do ::a:: end do ::a:: end", ["duplicate-label"]),
        ("goto nowhere", ["no-label"]),
        ("do ::inner:: end goto inner", ["no-label"]),
        ("goto later ::later::", []),
        ("local x <const> = 1; x = 2", ["assign-to-const"]),
        ("local x = 1; x = 2; print(x)", []),
        ("local t = {} t.x", ["not-a-statement"]),
        ("local f f() = 1", ["cannot-assign", "uninitialized"]),
        ("local unused = 1", ["unused"]),
        ("local _ = 1 local _ignored = 2", []),
        ("local a = 1 do local a = 2 print(a) end print(a)", ["shadowing"]),
        ("local a = 1 local a = a + 1 print(a)", []),
        ("local x print(x)", ["uninitialized"]),
        ("local x if y then x = 1 end print(x)", ["uninitialized"]),
        ("local x if y then x = 1 else x = 2 end print(x)", []),
        ("local a, b = 1 print(a, b)", []),
        ("local a, b a, b = 1, 2 print(a, b)", []),
        ("local x repeat x = 1 until x print(x)", []),
        ("local x for i = 1, 3 do x = i end print(x)", ["uninitialized"]),
        ("while true do print(1) end print(2)", ["unreachable"]),
        ("while true do if x then break end end print(2)", []),
        ("local function f(c) if c then return 1 else return 2 end print(3) end f()", ["unreachable"]),
        ("for i = i, 10 do print(i) end", []),
        ("local i = 1 for i = i, 10 do print(i) end", ["shadowing"]),
        ("local xs = {} for x in pairs(xs) do print(x) end", []),
    ],
)
def test_checks(source, expected):
    assert sorted(codes(source)) == sorted(expected)


def test_the_bounds_of_a_for_see_the_outer_variable():
    # `i` in the bounds is the outer local: it is used, and not the loop's own
    analysis = lua.RULES.analyze("local i = 3 for i = i, 10 do print(i) end")
    outer = next(s for s in analysis.symbols if s.name == "i" and s.namespace == "name")
    assert len(outer.uses) == 1


def test_syntax_errors_are_parse_errors():
    for source in ("x + 1", "local = 1", "if x then", "f(", "return return"):
        with pytest.raises(zgram.ParseError):
            lua.check(source)


def test_positions_and_messages():
    source = "local limit <const> = 10\nlimit = 11\nfor i = 1, 2 do end\nbreak\n"
    assert [(d.line, d.column, d.severity, d.message) for d in lua.check(source)] == [
        (2, 1, "error", "attempt to assign to const variable 'limit'"),
        (3, 5, "warning", "unused variable 'i'"),
        (4, 1, "error", "break outside a loop"),
    ]


CORPORA = [
    "/usr/share/nmap/nselib/*.lua",
    "/usr/share/nmap/scripts/*.nse",
    "/usr/share/sysdig/chisels/*.lua",
]


@pytest.mark.parametrize("pattern", CORPORA)
def test_shipped_lua_code_has_no_errors(pattern):
    """Code that runs in production parses, and nothing in it is an error."""
    files = sorted(glob.glob(pattern))
    if not files:
        pytest.skip(f"no files match {pattern}")
    warnings = 0
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as f:
            source = f.read()
        diagnostics = lua.check(source)
        errors = [d.render(source, path) for d in diagnostics if d.severity == "error"]
        assert errors == [], path
        warnings += len(diagnostics)
    # and the linter does find things in it
    assert warnings > 0
