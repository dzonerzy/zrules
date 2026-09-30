"""scopes(): definitions, uses, and the symbol table."""

import pytest
import zgram
from zrules import Rules, scopes

from conftest import found


def make(parser, **kwargs):
    options = dict(
        scope=("Program", "FuncDef"),
        define=("Let > .name", "FuncDef > .params"),
        define_outer="FuncDef > .name",
        use="Name",
        hoist="FuncDef > .name",
    )
    options.update(kwargs)
    return Rules(parser, [scopes(**options)])


class TestDiagnostics:
    def test_clean_program(self, parser):
        assert make(parser).check("let a = 1; fn f(x) { return x + a; } f(a);") == []

    def test_undefined(self, parser):
        assert found(make(parser), "let a = b; c(a);") == [("undefined-name", 1, 9, "b"), ("undefined-name", 1, 12, "c")]

    def test_redefined_in_the_same_scope(self, parser):
        rules = make(parser)
        (d,) = rules.check("let a = 1;\nlet a = 2;")
        assert (d.code, d.line, d.message) == ("redefined-name", 2, "'a' is already defined")
        assert [(n.message, n.line) for n in d.notes] == [("first defined here", 1)]

    def test_shadowing_is_allowed_by_default(self, parser):
        assert make(parser).check("let a = 1; fn f(a) { return a; }") == []

    def test_shadowing_reported_on_request(self, parser):
        rules = make(parser, on_shadow="warning")
        (d,) = rules.check("let a = 1; fn f(a) { return a; }")
        assert (d.severity, d.code, d.column) == ("warning", "shadowed-name", 17)
        assert d.notes[0].message == "the outer definition is here"

    def test_duplicate_parameters(self, parser):
        assert found(make(parser), "fn f(a, a) {}") == [("redefined-name", 1, 9, "a")]

    def test_use_before_definition_in_the_same_scope(self, parser):
        assert found(make(parser), "f(a); let a = 1; fn f(x) {}") == [("undefined-name", 1, 3, "a")]

    def test_a_name_is_visible_from_the_end_of_its_name(self, parser):
        assert make(parser).check("let a = a;") == []

    def test_after_makes_it_visible_once_the_declaration_ends(self, parser):
        rules = make(parser, after="Let > .name")
        assert found(rules, "let a = a;") == [("undefined-name", 1, 9, "a")]
        assert rules.check("let a = 1; let b = a; b;") == []
        # an outer `a` is what the initializer sees
        analysis = rules.analyze("let a = 1; fn f() { let a = a; return a; }")
        assert analysis.diagnostics == []
        outer, _, inner = analysis.symbols
        assert (len(outer.uses), len(inner.uses)) == (1, 1)

    def test_hoisted_definitions_are_visible_earlier(self, parser):
        assert make(parser).check("f(); fn f() {}") == []
        assert found(make(parser, hoist=()), "f(); fn f() {}") == [("undefined-name", 1, 1, "f")]

    def test_nested_scopes_see_later_outer_definitions(self, parser):
        assert make(parser).check("fn f() { return late; } let late = 1;") == []

    def test_unordered(self, parser):
        assert make(parser, ordered=False).check("f(a); let a = 1; fn f(x) {}") == []

    def test_locals_are_not_visible_outside(self, parser):
        assert found(make(parser), "fn f(p) { let q = p; } p; q;") == [("undefined-name", 1, 24, "p"), ("undefined-name", 1, 27, "q")]

    def test_function_name_belongs_to_the_outer_scope(self, parser):
        assert make(parser).check("fn f() { f(); } f();") == []
        # as a plain `define` it would be local to the function
        rules = make(parser, define=("Let > .name", "FuncDef > .params", "FuncDef > .name"), define_outer=(), hoist=())
        assert found(rules, "fn f() { f(); } f();") == [("undefined-name", 1, 17, "f")]

    def test_builtins(self, parser):
        assert make(parser, builtins=("print", "len")).check("print(len(print));") == []
        assert found(make(parser, builtins="print"), "print(len);") == [("undefined-name", 1, 7, "len")]

    def test_unused(self, parser):
        rules = make(parser, on_unused="warning")
        ds = rules.check("let a = 1; fn f(p, q) { return p; }")
        assert [(d.severity, d.code, d.column) for d in ds] == [("warning", "unused-name", 5), ("warning", "unused-name", 15), ("warning", "unused-name", 20)]

    def test_levels(self, parser):
        assert make(parser, on_undefined="ignore").check("a;") == []
        assert make(parser, on_undefined="warning").check("a;")[0].severity == "warning"
        assert make(parser, on_redefine="ignore").check("let a = 1; let a = 2;") == []

    def test_messages_and_codes(self, parser):
        rules = make(parser, messages={"undefined": "what is {text}?"}, codes={"undefined": "E001"})
        (d,) = rules.check("zz;")
        assert (d.code, d.message) == ("E001", "what is zz?")

    @pytest.mark.parametrize(
        "kwargs, exc",
        [
            ({"on_undefined": "fatal"}, ValueError),
            ({"messages": {"nope": "x"}}, ValueError),
            ({"messages": "x"}, TypeError),
            ({"codes": {"undefined": 5}}, TypeError),
            ({"scope": "Nope"}, ValueError),
            ({"use": 5}, TypeError),
            ({"builtins": [1]}, TypeError),
        ],
    )
    def test_bad_arguments(self, parser, kwargs, exc):
        with pytest.raises(exc):
            make(parser, **kwargs)

    def test_required_arguments(self):
        with pytest.raises(TypeError):
            scopes(scope="Program", define="Let")


class TestSymbols:
    SRC = "let a = 1;\nfn f(x) { return x + a; }\nf(a); print(a);"

    @pytest.fixture
    def analysis(self, parser):
        return make(parser, builtins=("print",)).analyze(self.SRC)

    def test_analysis(self, analysis):
        assert type(analysis).__name__ == "Analysis"
        assert analysis.ok and analysis.diagnostics == []
        assert type(analysis.tree).__name__ == "Tree"
        assert [s.name for s in analysis.symbols] == ["print", "a", "f", "x"]

    def test_symbol_fields(self, analysis):
        by_name = {s.name: s for s in analysis.symbols}
        a, f, x, pr = by_name["a"], by_name["f"], by_name["x"], by_name["print"]
        assert (a.namespace, a.builtin, a.span, a.scope) == ("name", False, (4, 5), 0)
        assert a.use_spans == [(32, 33), (39, 40), (49, 50)]
        assert [analysis.tree.node(i).text() for i in a.uses] == ["a", "a", "a"]
        assert analysis.tree.node(a.node).text() == "a"
        assert f.scope == 0 and len(f.uses) == 1
        assert analysis.tree.node(x.scope).rule() == "funcdef"
        assert (pr.builtin, pr.node, pr.span, pr.scope) == (True, None, None, None)
        assert len(pr.uses) == 1
        assert repr(a) == "Symbol('a', defined at 4..5, 3 uses)"
        assert repr(pr) == "Symbol('print', builtin, 1 uses)"

    def test_resolve_node_index_and_ast_object(self, parser, analysis):
        by_name = {s.name: s for s in analysis.symbols}
        root = analysis.tree.root
        uses = [n for n in root.find("ident") if n.text() == "a"]
        assert all(analysis.resolve(n) is by_name["a"] for n in uses)
        assert analysis.resolve(uses[1].index) is by_name["a"]
        assert analysis.resolve(root) is None
        assert analysis.resolve(10**6) is None
        with pytest.raises(TypeError):
            analysis.resolve("a")

    def test_resolve_ast_objects(self):
        from dataclasses import make_dataclass

        classes = {
            name: make_dataclass(name, fields.split())
            for name, fields in dict(Program="body", FuncDef="name params body", While="cond body", Return="value", Break="", Let="name value", BinOp="left op right", Call="name args", Name="text", Enum="name members", Member="target name", Import="module alias", FromImport="module names").items()
        }
        import conftest

        p = zgram.compile(conftest.GRAMMAR, ast=classes)
        tree = p.parse_tree("let a = 1; a + a;")
        analysis = make(p).analyze(tree)
        program = tree.root.to_ast()
        let, expr = program.body
        symbol = analysis.resolve(let.name)
        assert symbol.name == "a"
        assert analysis.resolve(expr.left) is symbol and analysis.resolve(expr.right) is symbol

    def test_at(self, analysis):
        by_name = {s.name: s for s in analysis.symbols}
        assert analysis.at(4) is by_name["a"]
        assert analysis.at(self.SRC.index("x + a")) is by_name["x"]
        assert analysis.at(self.SRC.index("print")) is by_name["print"]
        assert analysis.at(0) is None
        assert analysis.at(10**6) is None

    def test_redefinition_resolves_to_the_first(self, parser):
        analysis = make(parser).analyze("let a = 1; let a = 2; a;")
        assert not analysis.ok
        (a,) = analysis.symbols
        assert a.span == (4, 5) and len(a.uses) == 1
        second = [n for n in analysis.tree.root.find("ident")][1]
        assert analysis.resolve(second) is a

    def test_undefined_use_has_no_symbol(self, parser):
        analysis = make(parser).analyze("zz;")
        assert analysis.resolve(analysis.tree.root.find("ident")[0]) is None

    def test_namespaces(self, parser):
        rules = Rules(
            parser,
            [
                scopes(scope=("Program", "FuncDef"), define=("Let > .name", "FuncDef > .params"), use="Name:not(.name)", namespace="variable"),
                scopes(scope="Program", define="FuncDef > .name", use="Call > .name", ordered=False, namespace="function"),
            ],
        )
        analysis = rules.analyze("let f = 1; fn f(x) { return x; } f(f);")
        assert analysis.diagnostics == []
        assert sorted((s.namespace, s.name) for s in analysis.symbols) == [("function", "f"), ("variable", "f"), ("variable", "x")]
        call = analysis.tree.root.find("call")[0]
        assert analysis.resolve(call.get("name")).namespace == "function"
        assert analysis.resolve(call.get("args")).namespace == "variable"

    def test_analysis_outlives_rules_and_parser_variables(self):
        import gc

        import conftest

        analysis = make(zgram.compile(conftest.GRAMMAR), builtins=("print",), namespace="vars").analyze("let a = 1; print(a);")
        zgram.clear_cache()
        gc.collect()
        assert [(s.name, s.namespace, s.builtin) for s in analysis.symbols] == [("print", "vars", True), ("a", "vars", False)]
        assert analysis.at(4).use_spans == [(17, 18)]

    def test_symbols_are_the_same_objects_every_time(self, parser):
        analysis = make(parser).analyze("let a = 1; a;")
        assert analysis.symbols[0] is analysis.symbols[0] is analysis.at(4) is analysis.resolve(analysis.tree.root.find("ident")[0])

    def test_no_scopes_rule(self, parser):
        analysis = Rules(parser, []).analyze("let a = 1;")
        assert (analysis.symbols, analysis.ok) == ([], True)

    def test_ok_is_false_only_for_errors(self, parser):
        assert make(parser, on_unused="warning", on_undefined="warning").analyze("let a = b;").ok
        assert not make(parser).analyze("a;").ok

    def test_many_names(self, parser):
        names = ["v" + "".join(chr(97 + int(d)) for d in str(i)) for i in range(3000)]
        src = "".join(f"let {n} = 1;\n" for n in names) + "".join(f"{n};\n" for n in names) + "nope;"
        analysis = make(parser).analyze(src)
        assert len(analysis.symbols) == 3000
        assert [d.message for d in analysis.diagnostics] == ["undefined name 'nope'"]
        assert all(len(s.uses) == 1 for s in analysis.symbols)


class TestUnresolved:
    def test_hook_decides(self, parser):
        asked = []

        def known(node, ctx):
            asked.append((node.text(), type(ctx).__name__))
            return node.text().startswith("ext")

        rules = make(parser, on_unresolved=known)
        assert found(rules, "let a = 1; ext_x; nope; a; extra(a);") == [("undefined-name", 1, 19, "nope")]
        assert asked == [("ext_x", "Context"), ("nope", "Context"), ("extra", "Context")]

    def test_hook_can_report_its_own_diagnostic(self, parser):
        def suggest(node, ctx):
            ctx.error(node, f"unknown name '{node.text()}': did you mean 'alpha'?")
            return True

        rules = make(parser, on_unresolved=suggest)
        (d,) = rules.check("let alpha = 1; alpa;")
        assert (d.code, d.message) == ("undefined-name", "unknown name 'alpa': did you mean 'alpha'?")

    def test_hook_sees_the_symbols(self, parser):
        def close_match(node, ctx):
            return any(s.name.startswith(node.text()) for s in ctx.symbols)

        rules = make(parser, on_unresolved=close_match)
        assert [f[3] for f in found(rules, "let alpha = 1; alp; zz;")] == ["zz"]

    def test_hook_exception_propagates(self, parser):
        def boom(node, ctx):
            raise LookupError(node.text())

        with pytest.raises(LookupError, match="zz"):
            make(parser, on_unresolved=boom).check("zz;")

    def test_not_callable(self, parser):
        with pytest.raises(TypeError, match="callable"):
            make(parser, on_unresolved=5)

    def test_released_with_the_rules(self, parser):
        import gc
        import sys

        def hook(node, ctx):
            return True

        before = sys.getrefcount(hook)
        rules = make(parser, on_unresolved=hook)
        rules.check("zz;")
        del rules
        gc.collect()
        assert sys.getrefcount(hook) == before


class TestMembers:
    SRC = """enum color { red green }
enum shape { round }
let c = color.red;
let bad = color.blue;
shape.round; shape.red;
"""

    def rules(self, parser, **kwargs):
        return make(
            parser,
            scope=("Program", "FuncDef", "Enum"),
            define=("Let > .name", "FuncDef > .params", "Enum > .members"),
            define_outer=("FuncDef > .name", "Enum > .name"),
            members="Member",
            **kwargs,
        )

    def test_missing_member(self, parser):
        ds = self.rules(parser).check(self.SRC)
        assert [(d.code, d.message, d.line, d.column) for d in ds] == [
            ("no-member", "'color' has no member 'blue'", 4, 17),
            ("no-member", "'shape' has no member 'red'", 5, 20),
        ]
        assert [(n.message, n.line, n.column) for n in ds[0].notes] == [("defined here", 1, 6)]

    def test_members_are_not_visible_unqualified(self, parser):
        assert found(self.rules(parser), "enum color { red } red;") == [("undefined-name", 1, 20, "red")]

    def test_member_symbols(self, parser):
        analysis = self.rules(parser).analyze(self.SRC)
        by_name = {(s.name, s.scope): s for s in analysis.symbols}
        color = by_name[("color", 0)]
        red = [s for s in analysis.symbols if s.name == "red"][0]
        assert analysis.tree.node(color.owns).rule() == "enum_def"
        assert red.scope == color.owns and red.owns is None
        assert len(color.uses) == 2 and len(red.uses) == 1
        # the name and the whole access both resolve to the member
        member = analysis.tree.root.find("member")[0]
        assert analysis.resolve(member) is red
        assert analysis.resolve(member.get("name")) is red
        assert analysis.resolve(member.get("target")) is color

    def test_chained_access(self, parser):
        src = "enum outer { enum inner { leaf } } outer.inner.leaf; outer.inner.nope; outer.leaf;"
        ds = self.rules(parser).check(src)
        assert [d.message for d in ds] == ["'inner' has no member 'nope'", "'outer' has no member 'leaf'"]

    def test_access_on_a_variable_is_left_alone(self, parser):
        # what a variable holds is a question for types, not for names
        assert self.rules(parser).check("let v = 1; v.anything;") == []

    def test_access_on_an_undefined_name_reports_only_the_name(self, parser):
        assert [d.message for d in self.rules(parser).check("nope.x;")] == ["undefined name 'nope'"]

    def test_function_locals_are_members_of_nothing_useful(self, parser):
        # a function name owns its scope too: f.x finds its parameter
        assert self.rules(parser).check("fn f(x) {} f.x;") == []
        assert [d.message for d in self.rules(parser).check("fn f(x) {} f.y;")] == ["'f' has no member 'y'"]

    def test_levels_messages_and_codes(self, parser):
        assert self.rules(parser, on_no_member="ignore").check(self.SRC) == []
        rules = self.rules(parser, on_no_member="warning", messages={"no_member": "{owner}::{text}?"}, codes={"no_member": "E7"})
        d = rules.check(self.SRC)[0]
        assert (d.severity, d.code, d.message) == ("warning", "E7", "color::blue?")

    def test_member_labels(self, parser):
        with pytest.raises(ValueError, match="no label 'object'"):
            self.rules(parser, member_labels=("object", "name"))
        with pytest.raises(ValueError, match="two labels"):
            self.rules(parser, member_labels=("target",))

    def test_without_members_option_names_after_a_dot_are_plain_uses(self, parser):
        rules = make(parser, scope=("Program", "Enum"), define="Enum > .members", define_outer="Enum > .name")
        assert [d.message for d in rules.check("enum color { red } color.red;")] == ["undefined name 'red'"]
