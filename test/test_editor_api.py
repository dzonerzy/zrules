"""What editor tooling (zlsp) needs: Selector on its own, Analysis.visible(),
and both through capsules for native code."""

import ctypes
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


# ── The capsules, read as native code reads them ──

NONE = 0xFFFFFFFF


class Str(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("len", ctypes.c_size_t)]

    def get(self):
        return None if not self.ptr else ctypes.string_at(self.ptr, self.len).decode()


class Span(ctypes.Structure):
    _fields_ = [("start", ctypes.c_uint32), ("end", ctypes.c_uint32)]


class SymbolView(ctypes.Structure):
    _fields_ = [
        ("name", Str), ("namespace", Str), ("type", Str), ("origin_key", Str), ("origin_node", ctypes.c_uint32),
        ("module_key", Str), ("node", ctypes.c_uint32), ("def_", Span), ("scope", ctypes.c_uint32), ("owns", ctypes.c_uint32),
        ("uses_start", ctypes.c_uint32), ("uses_len", ctypes.c_uint32), ("flags", ctypes.c_uint32),
    ]


class AnalysisView(ctypes.Structure):
    _fields_ = [
        ("abi", ctypes.c_uint32), ("symbol_count", ctypes.c_uint32), ("symbols", ctypes.POINTER(SymbolView)),
        ("uses", ctypes.POINTER(Span)), ("use_nodes", ctypes.POINTER(ctypes.c_uint32)),
        ("import_count", ctypes.c_uint32), ("imports", ctypes.POINTER(Str)),
    ]


MATCH = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32))


class SelectorView(ctypes.Structure):
    _fields_ = [("abi", ctypes.c_uint32), ("ctx", ctypes.c_void_p), ("match", MATCH)]


GetPointer = ctypes.pythonapi.PyCapsule_GetPointer
GetPointer.restype = ctypes.c_void_p
GetPointer.argtypes = [ctypes.py_object, ctypes.c_char_p]


def opt(v):
    return None if v == NONE else v


class TestCapsules:
    def test_analysis(self):
        project = RULES.analyze_project({"lib": "struct P { a: int; }\nfn f(x: int) -> P { return P(x); }\n", "main": "from lib import f;\nlet p = f(1);\nprint(p.a);\n"})
        for key, imports in (("lib", []), ("main", ["lib"])):
            analysis = project.file(key)
            capsule = analysis.capsule
            view = AnalysisView.from_address(GetPointer(capsule, b"zrules.analysis.v2"))
            assert view.abi == 2 and view.symbol_count == len(analysis.symbols)
            assert [view.imports[k].get() for k in range(view.import_count)] == imports
            for i, s in enumerate(analysis.symbols):
                v = view.symbols[i]
                assert v.name.get() == s.name and v.namespace.get() == s.namespace
                assert v.type.get() == s.type
                assert opt(v.node) == s.node and ((v.def_.start, v.def_.end) if s.node is not None else None) == s.span
                assert opt(v.scope) == s.scope and opt(v.owns) == s.owns
                assert bool(v.flags & 1) == s.builtin
                uses = [(view.uses[v.uses_start + k].start, view.uses[v.uses_start + k].end) for k in range(v.uses_len)]
                assert uses == [tuple(u) for u in s.use_spans]
                assert [view.use_nodes[v.uses_start + k] for k in range(v.uses_len)] == list(s.uses)
                origin = (v.origin_key.get(), v.origin_node) if v.origin_key.get() is not None else None
                assert origin == (tuple(s.origin) if s.origin else None)
        # an import of a file that isn't there is listed too (an editor
        # checks the file with it once it appears)
        project = RULES.analyze_project({"main": "from lib import f;\nimport other;\nfrom lib import g;\n"})
        view = AnalysisView.from_address(GetPointer(project.file("main").capsule, b"zrules.analysis.v2"))
        assert [view.imports[k].get() for k in range(view.import_count)] == ["lib", "other"]
        # (the capsule keeps its analysis alive)
        capsule = RULES.analyze("let a = 1;").capsule
        view = AnalysisView.from_address(GetPointer(capsule, b"zrules.analysis.v2"))
        assert "a" in [view.symbols[i].name.get() for i in range(view.symbol_count)]

    def test_selector(self):
        tree = PARSER.parse_tree(SRC)
        sel = zrules.Selector(PARSER, "funcdef > .name, let_stmt > .name")
        capsule = sel.capsule
        view = SelectorView.from_address(GetPointer(capsule, b"zrules.selector.v1"))
        assert view.abi == 1
        tree_view = GetPointer(tree.capsule, b"zgram.tree.v1")
        out = (ctypes.c_uint32 * len(tree))()
        n = view.match(view.ctx, tree_view, out)
        assert list(out[:n]) == sel.match(tree)
        # a tree of another grammar: -2
        other = zgram.compile("x = 'x'").parse_tree("x")
        assert view.match(view.ctx, GetPointer(other.capsule, b"zgram.tree.v1"), out) == -2
