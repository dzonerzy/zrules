"""Custom rules: Python functions called on matching nodes."""

import gc

import pytest
from zrules import Rules, custom, forbid, scopes


def with_scopes(parser):
    return Rules(
        parser,
        [scopes(scope=("Program", "FuncDef"), define=("Let > .name", "FuncDef > .params"), define_outer="FuncDef > .name", use="Name", hoist="FuncDef > .name")],
    )


def test_custom_in_the_rule_list(parser):
    seen = []
    rules = Rules(parser, [custom("Call", lambda node, ctx: seen.append((type(node).__name__, node.text(), type(ctx).__name__)))])
    assert rules.check("f(1); g(h(2));") == []
    assert seen == [("Node", "f(1)", "Context"), ("Node", "g(h(2))", "Context"), ("Node", "h(2)", "Context")]


def test_decorator(parser):
    rules = Rules(parser)

    @rules.rule("Call[name=eval]", code="no-eval")
    def no_eval(node, ctx):
        ctx.error(node, "eval() is not allowed")

    assert callable(no_eval) and len(rules) == 1
    (d,) = rules.check("f(); eval(x);")
    assert (d.severity, d.code, d.message, d.span, d.line, d.column) == ("error", "no-eval", "eval() is not allowed", (5, 12), 1, 6)


def test_add(parser):
    rules = Rules(parser)
    def fn(node, ctx):
        ctx.warning(node, "a call")

    assert rules.add("Call", fn) is fn
    (d,) = rules.check("f();")
    assert (d.severity, d.code) == ("warning", "custom")


def test_severities_codes_and_spans(parser):
    rules = Rules(parser)

    @rules.rule("Let", code="default-code")
    def check(node, ctx):
        ctx.error(node.get("name"), "by node")
        ctx.warning(node.index, "by index", code="other")
        ctx.note((0, 3), "by span")

    ds = rules.check("let abc = 1;")
    assert [(d.severity, d.code, d.message, d.span) for d in ds] == [
        ("warning", "other", "by index", (0, 12)),
        ("note", "default-code", "by span", (0, 3)),
        ("error", "default-code", "by node", (4, 7)),
    ]


def test_resolve_and_parent(parser):
    rules = with_scopes(parser)

    @rules.rule("Call", code="arity")
    def arity(call, ctx):
        symbol = ctx.resolve(call.get("name"))
        if symbol is None:
            return
        func = ctx.tree.node(symbol.node).parent()
        expected, got = len(func.get_all("params")), len(call.get_all("args"))
        if expected != got:
            ctx.error(call, f"{symbol.name}() takes {expected}, got {got}")

    ds = rules.check("fn f(a, b) { return a + b; }\nf(1, 2); f(1); nope();")
    assert [(d.code, d.message) for d in ds] == [("arity", "f() takes 2, got 1"), ("undefined-name", "undefined name 'nope'")]


def test_context_symbols_and_tree(parser):
    rules = with_scopes(parser)
    seen = {}

    @rules.rule("Program")
    def look(node, ctx):
        seen["symbols"] = [s.name for s in ctx.symbols]
        seen["tree"] = type(ctx.tree).__name__
        seen["root"] = ctx.tree.root == node

    rules.check("let a = 1; fn f() {}")
    assert seen == {"symbols": ["a", "f"], "tree": "Tree", "root": True}


def test_results_are_merged_in_source_order(parser):
    rules = Rules(parser, [forbid("Break", message="native")])

    @rules.rule("Call")
    def calls(node, ctx):
        ctx.error(node, "python")

    assert [d.message for d in rules.check("f(); break; g(); break;")] == ["python", "native", "python", "native"]


def test_exception_propagates(parser):
    rules = Rules(parser)

    @rules.rule("Call")
    def boom(node, ctx):
        raise KeyError(node.text())

    with pytest.raises(KeyError, match="f"):
        rules.check("f();")
    # and the rules are still usable
    assert Rules(parser, [forbid("Break")]).check("break;") != []


def test_context_is_dead_after_the_check(parser):
    rules = Rules(parser)
    kept = []
    rules.add("Call", lambda node, ctx: kept.append(ctx))
    rules.check("f();")
    with pytest.raises(RuntimeError, match="finished"):
        kept[0].error(0, "too late")


@pytest.mark.parametrize("node", ["x", None, 3.5, 10**9, -1, (3, 1), ("a", "b")])
def test_bad_node_argument(parser, node):
    rules = Rules(parser)
    rules.add("Call", lambda n, ctx: ctx.error(node, "m"))
    with pytest.raises((TypeError, ValueError, IndexError)):
        rules.check("f();")


def test_not_callable(parser):
    with pytest.raises(TypeError, match="callable"):
        Rules(parser, [custom("Call", 5)])
    with pytest.raises(TypeError, match="callable"):
        Rules(parser).add("Call", "nope")
    with pytest.raises(ValueError, match="no rule or class"):
        Rules(parser).add("Nope", print)


def test_function_is_released_with_the_rules(parser):
    import sys

    def fn(node, ctx):
        pass

    before = sys.getrefcount(fn)
    rules = Rules(parser, [custom("Call", fn)])
    rules.add("Let", fn)
    rules.rule("Break")(fn)
    rules.check("f(); let a = 1; break;")
    assert sys.getrefcount(fn) == before + 3
    del rules
    gc.collect()
    assert sys.getrefcount(fn) == before
