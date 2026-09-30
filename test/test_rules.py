"""The five rule kinds."""

import pytest
import zgram
from zrules import Rules, count, forbid, inside, require, unique

from conftest import found


class TestInside:
    def test_flags_nodes_outside(self, parser):
        rules = Rules(parser, [inside("break_stmt", within="while_stmt")])
        assert found(rules, "break; while x { break; } break;") == [("inside", 1, 1, "break;"), ("inside", 1, 27, "break;")]

    def test_stop_at(self, parser):
        rules = Rules(parser, [inside("break_stmt", within="while_stmt", stop_at="funcdef", code="break-outside-loop")])
        src = "while x { break; fn f() { break; while y { break; } } }"
        assert found(rules, src) == [("break-outside-loop", 1, 27, "break;")]

    def test_several_within(self, parser):
        rules = Rules(parser, [inside("return_stmt", within=("funcdef", "while_stmt"))])
        assert found(rules, "return; fn f() { return 1; } while x { return; }") == [("inside", 1, 1, "return;")]

    def test_class_names(self, parser):
        by_rule = Rules(parser, [inside("break_stmt", within="while_stmt", stop_at="funcdef")])
        by_class = Rules(parser, [inside("Break", within="While", stop_at="FuncDef")])
        src = "break; while x { break; fn f() { break; } }"
        assert found(by_rule, src) == found(by_class, src) != []

    def test_within_is_required(self, parser):
        with pytest.raises(TypeError):
            inside("Break")
        with pytest.raises(ValueError, match="within"):
            Rules(parser, [inside("Break", within=())])


class TestUnique:
    def test_within_the_first_part(self, parser):
        rules = Rules(parser, [unique("FuncDef > .params", message="duplicate parameter '{text}'")])
        src = "fn f(a, b, a) {} fn g(a, b) {}"
        (d,) = rules.check(src)
        assert (d.message, d.span) == ("duplicate parameter 'a'", (11, 12))
        assert [(n.severity, n.message, n.span) for n in d.notes] == [("note", "first one is here", (5, 6))]

    def test_every_later_duplicate_is_flagged(self, parser):
        rules = Rules(parser, [unique("FuncDef > .params")])
        assert found(rules, "fn f(a, a, b, a, b) {}") == [("unique", 1, 9, "a"), ("unique", 1, 15, "a"), ("unique", 1, 18, "b")]

    def test_one_part_selector_is_unique_in_the_whole_tree(self, parser):
        rules = Rules(parser, [unique("Let.body")])
        assert found(rules, "let a = 1; let b = 2;") == []
        rules = Rules(parser, [unique("FuncDef")])
        assert [f[:3] for f in found(rules, "fn f() {} fn g() {} fn f() {}")] == [("unique", 1, 21)]

    def test_nested_scopes_are_separate(self, parser):
        rules = Rules(parser, [unique("program > FuncDef > .name")])
        src = "fn f() { fn f() {} } fn g() {} fn f() {}"
        assert found(rules, src) == [("unique", 1, 35, "f")]


class TestForbid:
    def test_every_match(self, parser):
        rules = Rules(parser, [forbid("Call > Call.args", message="nested call")])
        assert found(rules, "f(g(1), h(2)); k(1);") == [("forbid", 1, 3, "g(1)"), ("forbid", 1, 9, "h(2)")]

    def test_attribute(self, parser):
        rules = Rules(parser, [forbid("Call[name=eval]", code="no-eval", severity="warning")])
        (d,) = rules.check("f(1); eval(x); evaluate(y);")
        assert (d.severity, d.code, d.span) == ("warning", "no-eval", (6, 13))


class TestRequire:
    def test_parent_without_the_part(self, parser):
        rules = Rules(parser, [require("FuncDef > .params", code="no-params")])
        assert [f[:3] for f in found(rules, "fn f(a) {} fn g() {} fn h(b, c) {}")] == [("no-params", 1, 12)]

    def test_needs_two_parts(self, parser):
        with pytest.raises(ValueError, match="require"):
            Rules(parser, [require("FuncDef")])

    def test_descendant(self, parser):
        rules = Rules(parser, [require("FuncDef Return", message="function never returns")])
        src = "fn f() { while x { return 1; } } fn g() { let a = 1; }"
        assert [(d.message, d.column) for d in rules.check(src)] == [("function never returns", 34)]


class TestCount:
    def test_exactly(self, parser):
        rules = Rules(parser, [count("Call[name=len] > .args", exactly=1, message="len() takes one argument, got {count}")])
        msgs = [(d.message, d.column) for d in rules.check("len(a); len(); len(a, b); other();")]
        assert msgs == [("len() takes one argument, got 0", 9), ("len() takes one argument, got 2", 16)]

    def test_min_and_max(self, parser):
        rules = Rules(parser, [count("FuncDef > .params", min=1, max=2)])
        assert [f[2] for f in found(rules, "fn a() {} fn b(x) {} fn c(x, y) {} fn d(x, y, z) {}")] == [1, 36]

    def test_one_part_selector_counts_the_whole_tree(self, parser):
        rules = Rules(parser, [count("FuncDef", max=1, message="{count} functions")])
        assert rules.check("fn a() {}") == []
        (d,) = rules.check("fn a() {} fn b() {}")
        assert (d.message, d.span[0]) == ("2 functions", 0)

    @pytest.mark.parametrize("kwargs", [{}, {"exactly": 1, "min": 1}, {"min": -1}, {"exactly": "x"}])
    def test_bad_bounds(self, parser, kwargs):
        with pytest.raises((ValueError, TypeError)):
            Rules(parser, [count("FuncDef", **kwargs)])


class TestRules:
    def test_diagnostics_are_zgram_diagnostics_in_source_order(self, parser):
        rules = Rules(
            parser,
            [
                inside("Return", within="FuncDef", code="return-outside-function", message="'return' outside function"),
                inside("Break", within="While", stop_at="FuncDef", code="break-outside-loop", message="'break' outside loop"),
                unique("FuncDef > .params", code="duplicate-parameter", message="duplicate parameter '{text}'"),
            ],
        )
        src = "fn f(a, a) { break; }\nreturn 1;\n"
        ds = rules.check(src)
        assert all(type(d) is zgram.Diagnostic for d in ds)
        assert [(d.code, d.line, d.column) for d in ds] == [
            ("duplicate-parameter", 1, 9),
            ("break-outside-loop", 1, 14),
            ("return-outside-function", 2, 1),
        ]
        assert ds[1].render(src, "p.z") == "p.z:1:14: error: 'break' outside loop [break-outside-loop]\n    1 | fn f(a, a) { break; }\n      |              ^^^^^^"

    def test_accepts_text_tree_and_node(self, parser):
        rules = Rules(parser, [forbid("Break")])
        src = "break;"
        tree = parser.parse_tree(src)
        assert rules.check(src) == rules.check(src.encode()) == rules.check(tree) == rules.check(tree.root) == rules.check(parser.parse(src))
        assert len(rules.check(src)) == 1

    def test_syntax_error_in_text(self, parser):
        with pytest.raises(zgram.ParseError):
            Rules(parser, []).check("let = ;")

    def test_clean_source(self, parser):
        rules = Rules(parser, [forbid("Break"), unique("FuncDef > .params")])
        assert rules.check("fn f(a, b) { return a + b; }") == []

    def test_placeholders(self, parser):
        rules = Rules(parser, [forbid("Break", message="{rule}: '{text}' {{x}} {count}")])
        assert rules.check("break ;")[0].message == "break_stmt: 'break ;' {{x}} 0"

    def test_len_and_repr(self, parser):
        rules = Rules(parser, [forbid("Break"), forbid("Return")])
        assert len(rules) == 2
        assert repr(rules) == "Rules(2 rules)"
        assert repr(forbid("Break")) == "forbid(Break)"
        assert forbid("Break").kind == "forbid"

    def test_empty_rule_list(self, parser):
        assert Rules(parser, []).check("break;") == []

    def test_tree_from_another_grammar(self, parser):
        other = zgram.compile("a = 'x'")
        with pytest.raises(ValueError, match="different grammar"):
            Rules(parser, []).check(other.parse_tree("x"))

    def test_same_grammar_other_parser_object(self, parser):
        import conftest

        twin = zgram.compile(conftest.GRAMMAR)
        assert len(Rules(parser, [forbid("Break")]).check(twin.parse_tree("break;"))) == 1

    @pytest.mark.parametrize("bad", [5, None, object()])
    def test_check_argument_type(self, parser, bad):
        with pytest.raises(TypeError):
            Rules(parser, []).check(bad)

    def test_not_a_parser(self):
        with pytest.raises(TypeError, match="zgram parser"):
            Rules(object(), [])

    def test_not_a_rule(self, parser):
        with pytest.raises(TypeError, match=r"rules\[1\]"):
            Rules(parser, [forbid("Break"), "Break"])

    def test_severity(self, parser):
        with pytest.raises(ValueError, match="severity"):
            Rules(parser, [forbid("Break", severity="fatal")])

    def test_rules_outlive_the_parser_variable(self):
        import conftest

        rules = Rules(zgram.compile(conftest.GRAMMAR), [forbid("Break")])
        zgram.clear_cache()
        assert len(rules.check("break; break;")) == 2

    def test_large_input(self, parser):
        rules = Rules(parser, [inside("Break", within="While"), unique("FuncDef > .params")])
        src = "while x { break; }\n" * 5000 + "break;\n"
        ds = rules.check(src)
        assert [(d.line, d.column) for d in ds] == [(5001, 1)]


class TestWithin:
    def test_unique_within(self, parser):
        # without `within`, a one-part selector is unique over the whole tree
        src = "fn f(a) { let x = 1; let x = 2; } fn g(a) { let x = 3; }"
        whole = Rules(parser, [unique("Name.name")])
        assert [f[2] for f in found(whole, src)] == [26, 49]
        # a two-part selector groups by its first part: each Let is its own group
        assert found(Rules(parser, [unique("Let > .name")]), src) == []
        per_function = Rules(parser, [unique("Let > .name, .params", within="FuncDef")])
        assert found(per_function, src) == [("unique", 1, 26, "x")]

    def test_unique_within_spans_alternatives(self, parser):
        rules = Rules(parser, [unique("Let > .name, .params", within="FuncDef", message="'{text}' again")])
        (d,) = rules.check("fn f(a) { let a = 1; }")
        assert (d.message, d.column, d.notes[0].span) == ("'a' again", 15, (5, 6))

    def test_unique_outside_any_group(self, parser):
        rules = Rules(parser, [unique("Let > .name", within="FuncDef")])
        assert [f[2] for f in found(rules, "let a = 1; let a = 2; fn f() { let a = 3; }")] == [16]

    def test_count_within(self, parser):
        rules = Rules(parser, [count("Return", within="FuncDef", max=1, message="{count} returns, at most {max}")])
        ds = rules.check("fn f() { return 1; } fn g() { while x { return 1; } return 2; } fn h() {}")
        assert [(d.message, d.column) for d in ds] == [("2 returns, at most 1", 22)]

    def test_count_within_reports_empty_groups(self, parser):
        rules = Rules(parser, [count("Return", within="FuncDef", min=1)])
        assert [f[2] for f in found(rules, "fn f() { return 1; } fn h() {}")] == [22]

    def test_count_nearest_group(self, parser):
        rules = Rules(parser, [count("Break", within="While", max=1)])
        assert found(rules, "while a { break; while b { break; } }") == []


class TestPlaceholders:
    def test_all(self, parser):
        rules = Rules(parser, [count("FuncDef > .params", min=1, max=2, message="{rule} [{field}] in {parent}: {count} not in {min}..{max}: {text}")])
        (d,) = rules.check("fn f() {}")
        assert d.message == "funcdef [body] in program: 0 not in 1..2: fn f() {}"

    def test_unbounded_and_unknown(self, parser):
        rules = Rules(parser, [count("FuncDef > .params", min=1, message="{min}..{max} {nope} {")])
        assert rules.check("fn f() {}")[0].message == "1..any number {nope} {"

    def test_root_and_unlabelled(self, parser):
        rules = Rules(parser, [forbid("program", message="[{field}] [{parent}]")])
        assert rules.check("")[0].message == "[] []"


class TestRequireAlternatives:
    def test_each_alternative_is_checked(self, parser):
        rules = Rules(parser, [require("FuncDef > .params, While Break", message="{rule} incomplete")])
        ds = rules.check("fn f() { while x { } } fn g(a) { while y { break; } }")
        assert [(d.message, d.column) for d in ds] == [("funcdef incomplete", 1), ("while_stmt incomplete", 10)]

    def test_following_sibling(self, parser):
        rules = Rules(parser, [require("Let + *", message="'{text}' is the last statement")])
        assert [d.message for d in rules.check("let a = 1; f(); let b = 2;")] == ["'let b = 2;' is the last statement"]
