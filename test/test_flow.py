"""flow(): unreachable code, missing returns, variables used before they have a value."""

import pytest
import zgram
from zrules import Rules, flow, scopes, types

import typed
from typed import PARSER


def make(scope_options=None, **flow_options):
    options = dict(typed.FLOW)
    options.update(flow_options)
    options = {k: v for k, v in options.items() if v is not None}
    scope = dict(typed.SCOPES)
    scope["builtins"] = scope["builtins"] + typed.TYPES["basic"]
    scope.update(scope_options or {})
    return Rules(PARSER, [scopes(**scope), flow(**options)])


RULES = make()


def found(source, rules=RULES):
    return [(d.code, d.message, d.line, d.column) for d in rules.check(source)]


def messages(source, rules=RULES):
    return [d.message for d in rules.check(source)]


def in_fn(body):
    return "fn f(c) { " + body + " }"


class TestUnreachable:
    def test_after_return(self):
        ds = RULES.check("fn f() { return; print(1); print(2); }")
        assert [(d.code, d.severity, d.message, d.column) for d in ds] == [("unreachable", "warning", "unreachable code", 18)]
        assert "print(1);" in ds[0].render("fn f() { return; print(1); print(2); }", "x")

    def test_nothing_after_the_return(self):
        assert found("fn f() { print(1); return; }") == []

    def test_after_break_and_continue(self):
        source = in_fn("while c { break; print(1); } while c { continue; print(2); }")
        assert [(c, col) for c, _, _, col in found(source)] == [("unreachable", 28), ("unreachable", 60)]

    def test_after_a_branch_whose_arms_all_leave(self):
        assert messages(in_fn("if c { return; } else { return; } print(1);")) == ["unreachable code"]

    def test_not_after_a_branch_with_an_arm_that_goes_on(self):
        assert messages(in_fn("if c { return; } else { print(0); } print(1);")) == []
        assert messages(in_fn("if c { return; } print(1);")) == []

    def test_else_if_chains(self):
        assert messages(in_fn("if c { return; } else if c { return; } else { return; } print(1);")) == ["unreachable code"]
        assert messages(in_fn("if c { return; } else if c { return; } print(1);")) == []
        assert messages(in_fn("if c { return; } else if c { print(0); } else { return; } print(1);")) == []

    def test_after_a_loop_that_never_ends(self):
        assert messages(in_fn("loop { print(1); } print(2);")) == ["unreachable code"]
        assert messages(in_fn("loop { if c { break; } } print(2);")) == []
        assert messages(in_fn("loop { while c { break; } } print(2);")) == ["unreachable code"]

    def test_a_loop_with_a_condition_may_not_run(self):
        assert messages(in_fn("while c { return; } print(2);")) == []

    def test_do_while_runs_once(self):
        assert messages(in_fn("do { return; } while c; print(2);")) == ["unreachable code"]
        assert messages(in_fn("do { if c { break; } return; } while c; print(2);")) == []
        assert messages(in_fn("do { if c { continue; } return; } while c; print(2);")) == []

    def test_once_per_sequence(self):
        source = in_fn("return; print(1); if c { print(2); return; print(3); } print(4);")
        assert [col for _, _, _, col in found(source)] == [19]

    def test_nested_sequences_report_their_own(self):
        source = in_fn("if c { return; print(1); } while c { break; print(2); }")
        assert len(found(source)) == 2

    def test_top_level(self):
        assert messages("return; print(1);") == ["unreachable code"]

    def test_a_call_that_never_returns(self):
        rules = make(exits="return_stmt, call_args[target=exit]", scope_options={"builtins": ("print", "exit", "int")})
        assert messages(in_fn("exit(1); print(1);"), rules) == ["unreachable code"]
        assert messages("fn f() -> int { exit(1); }", rules) == []

    def test_function_after_a_return_is_not_dead_code(self):
        assert messages("fn f() { return g(); fn g() { return 1; } }") == []
        assert messages("fn f() { return g(); fn g() { return 1; } print(1); }") == ["unreachable code"]

    def test_inside_a_dead_function_the_flow_starts_again(self):
        assert [col for _, _, _, col in found("fn f() { return; fn g() { return; print(1); } }")] == [35]

    def test_level_and_texts(self):
        assert messages("fn f() { return; print(1); }", make(on_unreachable="ignore")) == []
        ds = make(on_unreachable="error", messages={"unreachable": "never runs: {rule}"}, codes={"unreachable": "W1"}).check("fn f() { return; let a = 1; }")
        assert [(d.severity, d.code, d.message) for d in ds] == [("error", "W1", "never runs: let_stmt")]


class TestMissingReturn:
    def test_end_can_be_reached(self):
        assert found("fn f() -> int { print(1); }") == [("missing-return", "'f' may end without returning a value", 1, 4)]

    def test_returns_on_every_path(self):
        assert found("fn f(c) -> int { if c { return 1; } else { return 2; } }") == []
        assert found("fn f(c) -> int { if c { return 1; } return 2; }") == []
        assert found("fn f(c) -> int { loop { if c { return 1; } } }") == []

    def test_a_path_without_return(self):
        assert messages("fn f(c) -> int { if c { return 1; } }") == ["'f' may end without returning a value"]
        assert messages("fn f(c) -> int { while c { return 1; } }") == ["'f' may end without returning a value"]
        assert messages("fn f(c) -> int { if c { return 1; } else if c { return 2; } }") == ["'f' may end without returning a value"]
        assert messages("fn f(c) -> int { loop { if c { break; } return 1; } }") == ["'f' may end without returning a value"]

    def test_only_functions_that_must(self):
        assert found("fn f() { print(1); } fn g() -> void { print(1); }") == []

    def test_nested_functions_are_separate(self):
        assert messages("fn f() -> int { fn g() -> int { return 1; } }") == ["'f' may end without returning a value"]
        assert messages("fn f() -> int { fn g() -> int { } return 1; }") == ["'g' may end without returning a value"]

    def test_methods(self):
        assert messages("struct P { x: int; fn m() -> int { } }") == ["'m' may end without returning a value"]

    def test_level(self):
        assert [d.severity for d in make(on_missing_return="warning").check("fn f() -> int { }")] == ["warning"]
        assert make(on_missing_return="ignore").check("fn f() -> int { }") == []

    def test_needs_functions(self):
        with pytest.raises(ValueError, match="needs `functions`"):
            make(functions=None)


class TestUnassigned:
    def test_used_before_any_value(self):
        assert found(in_fn("let x; print(x);")) == [("unassigned", "'x' is used before it has a value", 1, 24)]

    def test_given_a_value_first(self):
        assert found(in_fn("let x; x = 1; print(x);")) == []
        assert found(in_fn("let x = 1; print(x);")) == []

    def test_on_one_path_only(self):
        assert found(in_fn("let x; if c { x = 1; } print(x);")) == [("unassigned", "'x' may be used before it has a value", 1, 40)]

    def test_on_every_path(self):
        assert found(in_fn("let x; if c { x = 1; } else { x = 2; } print(x);")) == []
        assert found(in_fn("let x; if c { x = 1; } else if c { x = 2; } else { x = 3; } print(x);")) == []
        assert messages(in_fn("let x; if c { x = 1; } else if c { x = 2; } print(x);")) == ["'x' may be used before it has a value"]

    def test_a_path_that_leaves_does_not_count(self):
        assert found(in_fn("let x; if c { x = 1; } else { return; } print(x);")) == []
        assert found(in_fn("let x; while c { if c { x = 1; } else { continue; } print(x); }")) == []

    def test_its_own_value_is_read_first(self):
        assert messages(in_fn("let x; x = x + 1;")) == ["'x' is used before it has a value"]

    def test_reported_once(self):
        assert len(found(in_fn("let x; print(x); print(x); print(x + x);"))) == 1

    def test_loops(self):
        assert messages(in_fn("let x; while c { x = 1; } print(x);")) == ["'x' may be used before it has a value"]
        assert messages(in_fn("let x; while c { print(x); x = 1; }")) == ["'x' is used before it has a value"]
        assert messages(in_fn("let x; do { x = 1; } while c; print(x);")) == []
        assert messages(in_fn("let x; loop { x = 1; break; } print(x);")) == []
        assert messages(in_fn("let x; loop { if c { break; } x = 1; } print(x);")) == ["'x' may be used before it has a value"]
        assert messages(in_fn("let x; loop { x = 1; if c { break; } } print(x);")) == []
        assert messages(in_fn("let x; do { if c { continue; } x = 1; } while c; print(x);")) == ["'x' may be used before it has a value"]

    def test_in_a_condition(self):
        assert messages(in_fn("let x; if x { } ")) == ["'x' is used before it has a value"]
        assert messages(in_fn("let x; while x { x = 1; }")) == ["'x' is used before it has a value"]
        assert messages(in_fn("let x; do { x = true; } while x;")) == []

    def test_in_a_return(self):
        assert messages(in_fn("let x; return x;")) == ["'x' is used before it has a value"]

    def test_several_variables(self):
        names = [f"v{'abcdefghij'[i // 10]}{'abcdefghij'[i % 10]}" for i in range(100)]
        source = in_fn(" ".join(f"let {n};" for n in names) + " " + " ".join(f"{n} = 1;" for n in names[::2]) + " " + " ".join(f"print({n});" for n in names))
        assert messages(source) == [f"'{n}' is used before it has a value" for n in names[1::2]]

    def test_top_level(self):
        assert messages("let x; print(x); x = 1; print(x);") == ["'x' is used before it has a value"]

    def test_uses_in_nested_functions_are_not_judged(self):
        assert found("let x; fn f() { print(x); } x = 1; f();") == []
        assert found(in_fn("let x; fn g() { return x; } x = 1;")) == []

    def test_a_variable_given_a_value_by_another_function_is_not_followed(self):
        assert found("let x; fn init() { x = 1; } init(); print(x);") == []

    def test_members_and_items_are_not_the_variable(self):
        source = "struct P { x: int; } " + in_fn("let p; p.x = 1;")
        assert messages(source) == ["'p' is used before it has a value"]
        assert messages(in_fn("let xs; xs[0] = 1;")) == ["'xs' is used before it has a value"]
        assert found(in_fn("let p; p = 1; p.x = 2; print(p.x);")) == []

    def test_parameters_and_initialised_variables_are_not_followed(self):
        assert found("fn f(a) { print(a); let b = a; print(b); }") == []

    def test_dead_code_is_not_judged(self):
        assert [c for c, _, _, _ in found(in_fn("let x; return; print(x);"))] == ["unreachable"]

    def test_second_declaration_with_a_value(self):
        rules = make(scope_options={"on_redefine": "ignore"})
        assert found(in_fn("let x; let x = 1; print(x);"), rules) == []
        assert messages(in_fn("let x; let x; print(x);"), rules) == ["'x' is used before it has a value"]

    def test_level_and_texts(self):
        assert make(on_unassigned="ignore").check(in_fn("let x; print(x);")) == []
        rules = make(on_unassigned="warning", messages={"unassigned": "no value: {text}", "maybe_unassigned": "maybe no value: {text}"}, codes={"maybe_unassigned": "M"})
        ds = rules.check(in_fn("let x; let y; if c { y = 1; } print(x); print(y);"))
        assert [(d.severity, d.code, d.message) for d in ds] == [("warning", "unassigned", "no value: x"), ("warning", "M", "maybe no value: y")]


class TestAssignmentDefines:
    """A language where the first assignment to a name defines it."""

    GRAMMAR = r"""
    program = ws (stmt ws)*
    @silent stmt = funcdef | if_stmt | while_stmt | return_stmt | assign | expr_stmt
    funcdef = 'def' kw ws name:ident ws '(' ws (params:ident (ws ',' ws params:ident)*)? ws ')' ws block
    block = '{' ws (stmt ws)* '}'
    if_stmt = 'if' kw ws cond:expr ws then:block (ws 'else' kw ws else:block)?
    while_stmt = 'while' kw ws cond:expr ws block
    return_stmt = 'return' kw (ws value:expr)? ws ';'
    assign = lhs:ident ws '=' ws value:expr ws ';'
    @silent expr_stmt = expr ws ';'
    expr = atom (ws [+<] ws atom)*
    @silent atom = call | number | ident
    call = callee:ident '(' ws (expr (ws ',' ws expr)*)? ws ')'
    number = [0-9]+
    ident = !keyword [a-z_]+
    @silent keyword = ('def' | 'if' | 'else' | 'while' | 'return') kw
    @silent kw = ![a-z0-9_]
    @silent ws = [ \t\n]*
    """

    @pytest.fixture
    def rules(self):
        parser = zgram.compile(self.GRAMMAR)
        return Rules(
            parser,
            [
                scopes(
                    scope="program, funcdef",
                    define="assign > .lhs, funcdef > .params",
                    define_outer="funcdef > .name",
                    use="ident",
                    hoist="funcdef > .name",
                    ordered=False,
                    on_redefine="ignore",
                    builtins=("print",),
                ),
                flow(
                    sequences="program, block",
                    functions="funcdef",
                    branches="if_stmt",
                    arms="if_stmt > .then",
                    otherwise="if_stmt > .else",
                    loops="while_stmt",
                    exits="return_stmt",
                    assigns="assign",
                    labels={"target": "lhs"},
                ),
            ],
        )

    def test_defined_on_every_path(self, rules):
        assert rules.check("def f(c) { if c { x = 1; } else { x = 2; } print(x); }") == []
        assert rules.check("x = 1; print(x); x = x + 1;") == []

    def test_defined_on_one_path(self, rules):
        ds = rules.check("def f(c) { if c { x = 1; } print(x); }")
        assert [(d.message, d.column) for d in ds] == [("'x' may be used before it has a value", 34)]

    def test_used_before_the_assignment(self, rules):
        ds = rules.check("def f() { print(x); x = 1; }")
        assert [d.message for d in ds] == ["'x' is used before it has a value"]

    def test_defined_in_a_loop(self, rules):
        assert [d.message for d in rules.check("def f(c) { while c { y = 1; } return y; }")] == ["'y' may be used before it has a value"]

    def test_parameters_have_a_value(self, rules):
        assert rules.check("def f(a) { print(a); a = a + 1; print(a); }") == []


class TestOptions:
    def test_needs_sequences(self):
        with pytest.raises(ValueError, match="needs `sequences`"):
            Rules(PARSER, [flow(functions="funcdef")])

    def test_variables_need_a_scopes_rule(self):
        with pytest.raises(ValueError, match="needs a scopes"):
            Rules(PARSER, [flow(sequences="block", variables="let_stmt")])
        with pytest.raises(ValueError, match="no scopes\\(\\) rule has that namespace"):
            Rules(PARSER, [scopes(**typed.SCOPES), flow(sequences="block", assigns="assign", namespace="other")])

    def test_reachability_alone_needs_no_scopes_rule(self):
        rules = Rules(PARSER, [flow(sequences="program, block", functions="funcdef", exits="return_stmt")])
        assert [d.message for d in rules.check("fn f() { return; print(1); }")] == ["unreachable code"]

    @pytest.mark.parametrize(
        "options, exc, match",
        [
            ({"labels": {"nope": "x"}}, ValueError, "unknown role 'nope'"),
            ({"messages": {"nope": "x"}}, ValueError, "unknown kind 'nope'"),
            ({"codes": {"nope": "x"}}, ValueError, "unknown kind 'nope'"),
            ({"codes": "x"}, TypeError, "dict"),
            ({"on_unreachable": "fatal"}, ValueError, "'error', 'warning' or 'ignore'"),
            ({"branches": "Nope"}, ValueError, "no rule or class"),
        ],
    )
    def test_bad_options(self, options, exc, match):
        with pytest.raises(exc, match=match):
            make(**options)

    def test_arms_default_to_the_sequences_of_a_branch(self):
        rules = make(otherwise=None)
        # without `otherwise`, no branch is known to cover every case
        assert messages(in_fn("if c { return; } else { return; } print(1);"), rules) == []

    def test_with_types(self):
        rules = Rules(PARSER, [scopes(**typed.SCOPES), types(**typed.TYPES), flow(**typed.FLOW)])
        ds = rules.check('fn f(c: bool) -> int { let x: int; if c { x = 1; } let s: str = x; }')
        assert sorted(d.code for d in ds) == ["missing-return", "type-mismatch", "unassigned"]

    def test_in_a_project(self):
        project = RULES.analyze_project({"a": "fn f() -> int { }", "b": "from a import f;\nfn g() { return; f(); }"})
        assert [d.code for d in project.file("a").diagnostics] == ["missing-return"]
        assert [d.code for d in project.file("b").diagnostics] == ["unreachable"]


class TestDepthAndScale:
    def test_deeply_nested_blocks(self):
        depth = 400
        source = "fn f(c) { " + "if c { " * depth + "return; print(1);" + " }" * depth + " }"
        # past the depth the walk looks into, nothing is reported; nothing breaks either
        assert RULES.check(source) == []
        depth = 100
        source = "fn f(c) { " + "if c { " * depth + "return; print(1);" + " }" * depth + " }"
        assert [d.code for d in RULES.check(source)] == ["unreachable"]

    def test_deep_expressions(self):
        source = in_fn("let x; print(" + "(" * 300 + "x" + ")" * 300 + ");")
        assert messages(source) == ["'x' is used before it has a value"]

    def test_many_statements(self):
        import time

        def timed(n):
            body = "let a; let b; " + " ".join("if c { a = 1; } else { b = 2; } while c { a = b; break; }" for _ in range(n))
            tree = PARSER.parse_tree("fn f(c) { " + body + " }")
            best = float("inf")
            for _ in range(3):
                start = time.perf_counter()
                assert len(RULES.check(tree)) == 1
                best = min(best, time.perf_counter() - start)
            return best

        timed(100)
        # eight times the statements: nowhere near sixty-four times the time
        assert timed(8000) < 24 * max(timed(1000), 0.0005)

    def test_many_variables_and_branches_in_one_function(self):
        names = [f"v{'abcdefghij'[i % 10]}{'abcdefghij'[i // 10 % 10]}{'abcdefghij'[i // 100 % 10]}{'abcdefghij'[i // 1000 % 10]}" for i in range(5000)]
        body = " ".join(f"let {n}; if c {{ {n} = 1; }} else {{ {n} = 2; }} print({n});" for n in names)
        assert RULES.check("fn f(c) { " + body + " }") == []
