"""Selector syntax and matching, observed through forbid()."""

import pytest
from zrules import Rules, forbid

from conftest import found

SRC = "fn f(a, b) { let x = g(a, 1) + h(b); while x { break; } return x; }"


def texts(parser, selector, src=SRC):
    return [f[3] for f in found(Rules(parser, [forbid(selector)]), src)]


def test_rule_name(parser):
    assert texts(parser, "call") == ["g(a, 1)", "h(b)"]


def test_class_name_covers_every_rule_mapped_to_it(parser):
    assert texts(parser, "Call") == texts(parser, "call")
    assert texts(parser, "Name") == texts(parser, "ident")


def test_star(parser):
    assert len(texts(parser, "*", "break;")) == 2  # program and break_stmt


def test_field(parser):
    assert texts(parser, ".cond") == ["x"]
    assert texts(parser, ".params") == ["a", "b"]


def test_name_and_field(parser):
    assert texts(parser, "ident.name") == ["f", "x", "g", "h"]
    assert texts(parser, "Call.left") == ["g(a, 1)"]


def test_child(parser):
    assert texts(parser, "funcdef > ident") == ["f", "a", "b"]
    assert texts(parser, "while_stmt > ident") == ["x"]


def test_descendant(parser):
    assert texts(parser, "while_stmt break_stmt") == ["break;"]
    assert texts(parser, "let_stmt number") == ["1"]
    assert texts(parser, "funcdef number") == ["1"]


def test_three_parts(parser):
    assert texts(parser, "funcdef > block > let_stmt") == ["let x = g(a, 1) + h(b);"]
    assert texts(parser, "funcdef call > ident.args") == ["a", "b"]
    assert texts(parser, "program > block") == []


def test_descendant_backtracks_over_ancestors(parser):
    src = "while a { fn f() { while b { break; } } }"
    # the break's nearest `while` is not a direct child of program, the outer one is
    assert texts(parser, "program > while_stmt break_stmt", src) == ["break;"]


def test_attribute(parser):
    assert texts(parser, "call[name=g]") == ["g(a, 1)"]
    assert texts(parser, "call[name=g] > .args") == ["a", "1"]
    assert texts(parser, "call[ name = 'h' ]") == ["h(b)"]
    assert texts(parser, 'call[name="nope"]') == []


def test_two_attributes(parser):
    assert texts(parser, "expr[left=x][right=y]", "x + y; x + z;") == ["x + y"]


def test_attribute_looks_at_direct_children_only(parser):
    assert texts(parser, "funcdef[name=g]") == []
    assert texts(parser, "funcdef[name=f]") == [SRC]


def test_whitespace_is_free(parser):
    assert texts(parser, "  funcdef>ident  ") == texts(parser, "funcdef > ident") == texts(parser, "funcdef   >   ident")


@pytest.mark.parametrize(
    "selector, message",
    [
        ("Nope", "no rule or class 'Nope'"),
        ("call > .zzz", "no label 'zzz'"),
        ("call[zzz=1]", "no label 'zzz'"),
        ("", "empty"),
        ("   ", "empty"),
        ("call >", "malformed"),
        ("> call", "malformed"),
        ("call[name]", "malformed"),
        ("call[name=x", "malformed"),
        ("call.", "malformed"),
        ("call!", "malformed"),
    ],
)
def test_errors(parser, selector, message):
    with pytest.raises(ValueError, match=message):
        Rules(parser, [forbid(selector)])


def test_selector_must_be_a_string(parser):
    with pytest.raises(TypeError):
        Rules(parser, [forbid(5)])


class TestPseudoClasses:
    def test_not(self, parser):
        assert texts(parser, "ident:not(.name)") == ["a", "b", "a", "b", "x", "x"]
        assert texts(parser, "ident:not(.name):not(.params)") == ["a", "b", "x", "x"]
        assert texts(parser, "call:not([name=g])") == ["h(b)"]
        assert texts(parser, "*.cond:not(ident)") == []

    def test_has_child(self, parser):
        src = "f(); g(1); h(k(2));"
        assert texts(parser, "call:has(> .args)", src) == ["g(1)", "h(k(2))", "k(2)"]

    def test_has_descendant(self, parser):
        src = "f(); g(1); h(k(2));"
        assert texts(parser, "call:has(call)", src) == ["h(k(2))"]
        assert texts(parser, "call:has(number)", src) == ["g(1)", "h(k(2))", "k(2)"]
        assert texts(parser, "call:has(> number)", src) == ["g(1)", "k(2)"]

    def test_has_with_a_longer_selector(self, parser):
        src = "fn f() { while x { break; } } fn g() { while y { z; } }"
        assert [t[:6] for t in texts(parser, "funcdef:has(while_stmt > block > break_stmt)", src)] == ["fn f()"]

    def test_has_stays_inside_the_node(self, parser):
        # the sibling's call must not count
        assert texts(parser, "let_stmt:has(call)", "let a = 1; f(2);") == []

    def test_nth(self, parser):
        src = "fn f(a, b, c) {} fn g(d) {}"
        assert texts(parser, ".params:nth(1)", src) == ["a", "d"]
        assert texts(parser, ".params:nth(2)", src) == ["b"]
        assert texts(parser, ".params:nth(3)", src) == ["c"]
        assert texts(parser, ".params:nth(4)", src) == []

    def test_first_and_last(self, parser):
        src = "fn f(a, b, c) {} fn g(d) {}"
        assert texts(parser, ".params:first", src) == ["a", "d"]
        assert texts(parser, ".params:last", src) == ["c", "d"]
        assert texts(parser, "funcdef:last", src) == ["fn g(d) {}"]
        assert texts(parser, ".params:first:last", src) == ["d"]

    def test_nth_counts_only_matching_siblings(self, parser):
        # the function's name is an ident too, but not a .params
        assert texts(parser, "funcdef > ident:nth(2)", "fn f(a, b) {}") == ["a"]
        assert texts(parser, "funcdef > ident.params:nth(2)", "fn f(a, b) {}") == ["b"]

    def test_combined_with_combinators(self, parser):
        src = "fn f(a, b) { g(a, b); }"
        assert texts(parser, "call > .args:last", src) == ["b"]
        assert texts(parser, "funcdef:has(call[name=g]) > .params:first", src) == ["a"]

    @pytest.mark.parametrize(
        "selector",
        ["call:nope", "call:nth", "call:nth(0)", "call:nth(x)", "call:not", "call:not()", "call:not(a > b)", "call:has()", "call:has(", "call:has(>)"],
    )
    def test_malformed(self, parser, selector):
        with pytest.raises(ValueError):
            Rules(parser, [forbid(selector)])

    def test_unknown_names_inside_pseudo_classes(self, parser):
        with pytest.raises(ValueError, match="no rule or class 'Nope'"):
            Rules(parser, [forbid("call:has(Nope)")])
        with pytest.raises(ValueError, match="no label 'zzz'"):
            Rules(parser, [forbid("call:not(.zzz)")])

    def test_too_many_parts(self, parser):
        with pytest.raises(ValueError, match="malformed"):
            Rules(parser, [forbid(" > ".join(["block"] * 17))])
        Rules(parser, [forbid(" > ".join(["block"] * 16))])
