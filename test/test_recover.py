"""Trees parsed with zgram's recover=True: syntax errors among the diagnostics,
and nothing reported about the broken text or because of it."""

import os
import sys

import pytest
import zgram

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples", "typed"))
import typedlang  # noqa: E402

RULES = typedlang.RULES
PARSER = typedlang.PARSER


def found(source):
    return [(d.line, d.column, d.code) for d in RULES.check(source, recover=True)]


class TestSyntaxErrors:
    def test_listed_with_the_findings_in_source_order(self):
        src = "print(nope);\nlet b = * 2;\nprint(other);\n"
        ds = RULES.check(src, recover=True)
        assert [(d.line, d.code) for d in ds] == [(1, "undefined-name"), (2, "syntax"), (3, "undefined-name")]
        assert ds[1].message == "expected expr" and ds[1].severity == "error"

    def test_the_same_diagnostics_as_the_tree(self):
        tree = PARSER.parse_tree("let b = * 2;\nprint(nope);\n", recover=True)
        assert [d for d in RULES.check(tree) if d.code == "syntax"] == tree.errors
        assert RULES.check(tree) == RULES.check("let b = * 2;\nprint(nope);\n", recover=True)
        assert RULES.check(tree.root) == RULES.check(tree)

    def test_without_recover_text_still_raises(self):
        with pytest.raises(zgram.ParseError, match="expected expr"):
            RULES.check("let b = * 2;")
        with pytest.raises(zgram.ParseError):
            RULES.analyze_project({"main": "let b = * 2;"})

    def test_analyze_and_projects(self):
        analysis = RULES.analyze("let b = * 2;\n", recover=True)
        assert [d.code for d in analysis.diagnostics] == ["syntax"]
        project = RULES.analyze_project({"main": "let b = * 2;\n", "other": "let c = 1;\n"}, recover=True)
        assert [d.code for d in project.file("main").diagnostics] == ["syntax"]
        assert project.file("other").diagnostics == []

    def test_valid_text_is_checked_the_same(self):
        src = "fn two(a: int, b: int) -> int { return a + b; }\nprint(two(1));\n"
        assert RULES.check(src, recover=True) == RULES.check(src) == RULES.check(PARSER.parse_tree(src))


class TestNothingAboutBrokenText:
    def test_a_call_with_a_broken_argument(self):
        # two(1, +) would be an arity error without its broken argument
        src = "fn two(a: int, b: int) -> int { return a + b; }\nprint(two(1, +));\nprint(two(1));\n"
        assert found(src) == [(2, 14, "syntax"), (3, 7, "arity")]

    def test_a_name_defined_in_broken_text_is_not_undefined(self):
        assert found("let b = * 2;\nprint(b);\nprint(nope);\n") == [(1, 9, "syntax"), (3, 7, "undefined-name")]

    def test_a_name_exported_from_broken_text(self):
        geometry = "fn area(w: float, h: float -> float { return w * h; }\nfn perimeter(w: float) -> float { return 4.0 * w; }\n"
        main = "from geometry import area, perimeter, volume;\nprint(area(1.0, 2.0));\n"
        project = RULES.analyze_project({"geometry": geometry, "main": main}, recover=True)
        # area's definition didn't parse; volume doesn't exist anywhere
        assert [(d.code, d.message) for d in project.file("main").diagnostics] == [("no-export", "module 'geometry' has no 'volume'")]
        assert all(d.code == "syntax" for d in project.file("geometry").diagnostics)


class TestFlowAroundBrokenText:
    def test_a_broken_return_is_not_a_missing_return(self):
        src = "fn f(x: int) -> int {\n    return x +;\n}\nfn g(x: int) -> int {\n    if x > 0 { return 1; }\n}\n"
        # f's body is broken: its paths can't be followed; g's still are
        assert found(src) == [(2, 15, "syntax"), (4, 4, "missing-return")]

    def test_an_unclosed_function_doesnt_make_the_rest_unreachable(self):
        src = "fn f() -> int {\n    if true {\n        return 1;\n    } else {\n        return 2;\n    }\nprint(1);\n"
        assert [code for _, _, code in found(src)] == ["syntax"]

    def test_a_variable_given_its_value_in_broken_text(self):
        src = "fn f() -> int {\n    let x: int;\n    x = * 1;\n    return x;\n}\nfn g() -> int {\n    let y: int;\n    return y;\n}\n"
        assert [(line, code) for line, _, code in found(src)] == [(3, "syntax"), (8, "unassigned")]


class TestUnknownTypes:
    def test_an_item_of_unknown_type_makes_a_list_of_unknown(self):
        # [nope, 1] is not list[int]: nope could be a float
        src = "let xs: list[float] = [nope, 1];\nlet ys: list[str] = [1, 2];\n"
        assert [code for _, _, code in found(src)] == ["undefined-name", "type-mismatch"]
        assert [code for _, _, code in found("let xs = [1, nope, \"a\"];\n")] == ["undefined-name", "type-mismatch"]
