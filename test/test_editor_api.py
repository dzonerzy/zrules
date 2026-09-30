"""What editor tooling (zlsp) needs: Selector on its own, Analysis.visible()."""

import os
import sys

import pytest
import zgram
import zrules

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples", "typed"))
import typedlang  # noqa: E402

PARSER = typedlang.PARSER
RULES = typedlang.RULES

SRC = "fn f(a: int) -> int {\n    let b = a;\n    \n    return b;\n}\nlet top = 1;\nlet later = top;\n"


class TestSelector:
    def test_match(self):
        tree = PARSER.parse_tree(SRC)
        s = zrules.Selector(PARSER, "funcdef > .name, let_stmt > .name")
        assert [tree.node(i).text() for i in s.match(tree)] == ["f", "b", "top", "later"]
        # a Node stands for its tree
        assert s.match(tree.root) == s.match(tree)

    def test_the_selector_language(self):
        tree = PARSER.parse_tree(SRC)
        params = zrules.Selector(PARSER, "funcdef param > .name")
        assert [tree.node(i).text() for i in params.match(tree)] == ["a"]
        assert zrules.Selector(PARSER, "return_stmt:has(ident)").match(tree) != []
        assert zrules.Selector(PARSER, "while_stmt").match(tree) == []

    def test_recovered_trees(self):
        tree = PARSER.parse_tree("let a = * 1;\nlet b = 2;\n", recover=True)
        s = zrules.Selector(PARSER, "let_stmt > .name")
        assert [tree.node(i).text() for i in s.match(tree)] == ["b"]

    def test_errors(self):
        with pytest.raises(ValueError, match="no rule or class 'nope'"):
            zrules.Selector(PARSER, "nope")
        with pytest.raises(ValueError, match="malformed"):
            zrules.Selector(PARSER, "funcdef >")
        other = zgram.compile("x = 'x'")
        with pytest.raises(ValueError, match="different grammar"):
            zrules.Selector(PARSER, "funcdef").match(other.parse_tree("x"))
        with pytest.raises(TypeError):
            zrules.Selector(PARSER, "funcdef").match(42)


@pytest.fixture(scope="module")
def analysis():
    return RULES.analyze(SRC)


class TestVisible:
    def names(self, analysis, at):
        return [s.name for s in analysis.visible(at) if not s.builtin]

    def test_ordered_in_its_own_scope(self, analysis):
        # b only from its definition on; the top level's names from a function
        assert self.names(analysis, SRC.index("let b")) == ["a", "f", "top", "later"]
        assert self.names(analysis, SRC.index("    \n") + 4) == ["a", "b", "f", "top", "later"]
        assert self.names(analysis, SRC.index("let later")) == ["f", "top"]

    def test_builtins_last(self, analysis):
        symbols = analysis.visible(SRC.index("let later"))
        assert [s.builtin for s in symbols] == sorted(s.builtin for s in symbols)
        assert "print" in [s.name for s in symbols]

    def test_inner_names_hide_outer_ones(self):
        src = "let a = 1;\nfn f(a: str) -> str {\n    return a;\n}\n"
        analysis = RULES.analyze(src)
        at = src.index("return")
        visible = [s for s in analysis.visible(at) if s.name == "a"]
        assert len(visible) == 1 and visible[0].span[0] == src.index("a: str")

    def test_namespace(self, analysis):
        assert analysis.visible(0, namespace="name") == analysis.visible(0)
        with pytest.raises(ValueError, match="no scopes"):
            analysis.visible(0, namespace="nope")

    def test_without_scopes(self):
        analysis = zrules.Rules(PARSER, []).analyze(SRC)
        assert analysis.visible(5) == []
