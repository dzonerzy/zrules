"""examples/typed: a typed language checked by structure, names, types and flow together."""

import os
import sys

HERE = os.path.join(os.path.dirname(__file__), "..", "examples", "typed")
sys.path.insert(0, HERE)
import typedlang  # noqa: E402


def read(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


def check(*names):
    project = typedlang.RULES.analyze_project({os.path.splitext(n)[0]: read(n) for n in names})
    return {os.path.splitext(n)[0]: [(d.line, d.code) for d in project.file(os.path.splitext(n)[0]).diagnostics] for n in names}


def test_the_valid_program_is_clean():
    assert check("geometry.ty", "main.ty") == {"geometry": [], "main": []}


def test_types_come_through_the_import():
    project = typedlang.RULES.analyze_project({"geometry": read("geometry.ty"), "main": read("main.ty")})
    types = {s.name: s.type for s in project.file("main").symbols if not s.builtin}
    assert types["end"] == "Point"
    assert types["xs"] == "list[float]"
    assert types["top"] == "float?"
    assert types["largest"] == "fn(list[float]) -> float?"


def test_every_mistake_is_found():
    assert check("geometry.ty", "mistakes.ty") == {
        "geometry": [],
        "mistakes": [
            (1, "no-export"),
            (3, "missing-return"),
            (9, "redefined-name"),
            (14, "unassigned"),
            (15, "unreachable"),
            (19, "bad-argument"),
            (20, "type-mismatch"),
            (20, "no-field"),
            (21, "arity"),
            (21, "bad-operand"),
            (22, "break-outside-loop"),
        ],
    }


def test_command_line(capsys):
    assert typedlang.check_files([os.path.join(HERE, "geometry.ty"), os.path.join(HERE, "main.ty")]) == 0
    assert typedlang.check_files([os.path.join(HERE, "geometry.ty"), os.path.join(HERE, "mistakes.ty")]) == 1
    err = capsys.readouterr().err
    assert "mistakes.ty:14:12: error: 'result' may be used before it has a value [unassigned]" in err
    assert "mistakes.ty:15:5: warning: unreachable code [unreachable]" in err
