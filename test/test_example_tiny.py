"""examples/tiny: a language whose static errors are all found by zrules."""

import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples", "tiny"))
import tiny  # noqa: E402

FIB = open(os.path.join(os.path.dirname(tiny.__file__), "fib.tiny"), encoding="utf-8").read()


def run(source):
    out, errors = [], []
    ok = tiny.run(source, output=lambda *a: out.append(" ".join(a)), errors=errors.append)
    return ok, out, [e.splitlines()[0] for e in errors]


def test_fibonacci():
    assert run(FIB) == (True, ["0", "1", "1", "2", "3", "5", "8", "13", "21", "34"], [])


@pytest.mark.parametrize(
    "source, output",
    [
        ('print("a\\tb", 1.5, 4 / 2, 1 == 1, 2 < 1);', ["a\tb 1.5 2 true false"]),
        ("let i = 0; while 1 < 2 { i = i + 1; if i >= 3 { break; } } print(i);", ["3"]),
        ("fn f() { return; } print(f());", ["nothing"]),
        ("fn even(n) { if n == 0 { return 1 == 1; } return odd(n - 1); }\nfn odd(n) { if n == 0 { return 1 == 2; } return even(n - 1); }\nprint(even(10));", ["true"]),
        ("let g = 5; fn f(a) { let b = a + g; return b + late; } let late = 1; print(f(1));", ["7"]),
        ("fn f(n) { if n == 0 { return 0; } let x = n; let r = f(n - 1); return x + r; } print(f(4));", ["10"]),
    ],
)
def test_programs(source, output):
    assert run(source) == (True, output, [])


def test_every_static_error_is_reported_before_running():
    source = """fn add(a, b) { return a + b; }
print("never printed");
let x = add(1);
break;
fn twice(f, f) { return nope(f) + y; }
print(add, x(2));
let x = 3;
return 1;
fn outer() { fn inner() {} }
"""
    ok, out, errors = run(source)
    assert (ok, out) == (False, [])
    assert errors == [
        "<tiny>:3:9: error: add() takes 2 arguments, got 1 [arity]",
        "<tiny>:4:1: error: 'break' outside loop [break-outside-loop]",
        "<tiny>:5:13: error: 'f' is already defined [redefined-name]",
        "<tiny>:5:25: error: undefined name 'nope' [undefined-name]",
        "<tiny>:5:35: error: undefined name 'y' [undefined-name]",
        "<tiny>:6:7: error: function 'add' used as a value [function-as-value]",
        "<tiny>:6:12: error: 'x' is not a function [not-a-function]",
        "<tiny>:7:5: error: 'x' is already defined [redefined-name]",
        "<tiny>:8:1: error: 'return' outside function [return-outside-function]",
        "<tiny>:9:14: error: functions cannot be defined inside functions [nested-function]",
    ]


def test_syntax_error():
    assert run("let x = 1 + ;") == (False, [], ["<tiny>:1:13: error: expected expression [syntax]"])


@pytest.mark.parametrize(
    "source, error",
    [
        ("fn f() { return late; } print(f()); let late = 1;", "<tiny>:1:17: error: 'late' is used before it has a value [unassigned]"),
        ('print(1 + "a");', "<tiny>:1:7: error: cannot apply '+' to number and string [type-mismatch]"),
        ("print(7 / 0);", "<tiny>:1:7: error: division by zero [division-by-zero]"),
    ],
)
def test_errors_left_for_run_time(source, error):
    ok, _, errors = run(source)
    assert (ok, errors) == (False, [error])


def test_the_interpreter_has_no_static_checks():
    import inspect

    text = inspect.getsource(tiny.Interpreter)
    for gone in ("undefined", "outside", "arity", "takes"):
        assert gone not in text
