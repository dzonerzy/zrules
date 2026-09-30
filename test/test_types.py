"""types(): declared and inferred types, and the checks on them."""

import gc

import pytest
from zrules import Rules, scopes, types

import typed
from typed import PARSER, RULES, make, messages, problems


def type_of(source, text, rules=RULES, occurrence=0):
    """The type of the `occurrence`-th node whose text is `text`."""
    analysis = rules.analyze(source)
    tree = analysis.tree
    nodes = [tree.node(i) for i in range(len(tree)) if tree.node(i).text() == text]
    # the innermost node with that text: the expression itself, not a wrapper
    return analysis.type_of(nodes[occurrence])


def symbol_types(source, rules=RULES):
    return {s.name: s.type for s in rules.analyze(source).symbols if not s.builtin}


class TestClean:
    def test_typed_program(self):
        source = """
        struct Point { x: int; y: int; fn norm() -> float { return 1.5; } }
        fn add(a: int, b: int) -> int { return a + b; }
        let p = Point(1, 2);
        let n: int = add(p.x, p.y);
        let f: float = p.norm() + n;
        if n < 3 { print(f); }
        """
        assert problems(source) == []

    def test_untyped_program_has_no_type_errors(self):
        source = """
        fn add(a, b) { return a + b; }
        let n = add(1, "two");
        if n { n(); n.anything; }
        """
        assert problems(source) == []


class TestInference:
    def test_literals(self):
        source = 'let a = 1; let b = 1.5; let c = "s"; let d = true; let e = nil;'
        assert symbol_types(source) == {"a": "int", "b": "float", "c": "str", "d": "bool", "e": "nil"}

    def test_variable_takes_its_annotation_over_its_value(self):
        assert symbol_types("let f: float = 1;") == {"f": "float"}

    def test_through_variables_calls_and_operators(self):
        source = "fn sq(v: int) -> int { return v * v; } let a = sq(2); let b = a + 1; let c = b < 3; let d = a + 1.5;"
        assert symbol_types(source) == {"sq": "fn(int) -> int", "v": "int", "a": "int", "b": "int", "c": "bool", "d": "float"}

    def test_unannotated_function_result_is_unknown(self):
        assert symbol_types("fn f(a) { return 1; } let x = f(2);") == {"f": "fn(unknown) -> unknown", "a": None, "x": None}

    def test_variable_defined_in_terms_of_itself(self):
        assert symbol_types("let a = a;", make(scope_options={"after": ()})) == {"a": None}

    def test_use_before_definition_of_a_function(self):
        assert symbol_types("let n = f(); fn f() -> int { return 1; }")["n"] == "int"

    def test_lists(self):
        assert symbol_types("let a = [1, 2]; let b = [1, 2.5]; let c = []; let d = [[1]];") == {
            "a": "list[int]",
            "b": "list[float]",
            "c": "list[unknown]",
            "d": "list[list[int]]",
        }

    def test_list_items_must_agree(self):
        assert problems('let a = [1, "x", 2];') == [("type-mismatch", "expected an item of type 'int', got 'str'", 1, 13)]

    def test_parentheses_and_nesting(self):
        assert type_of("let a = (1 + 2) * 3;", "(1 + 2) * 3") == "int"
        assert type_of("let a = (1 + 2.0) * 3;", "(1 + 2.0) * 3") == "float"

    def test_type_of_nodes(self):
        source = "fn f(a: int) -> str { return \"x\"; } let v = f(1);"
        assert type_of(source, "f(1)") == "str"
        assert type_of(source, "int") == "int"
        assert type_of(source, '"x"') == "str"
        analysis = RULES.analyze(source)
        assert analysis.type_of(analysis.tree.root) is None
        assert analysis.type_of(10**6) is None
        with pytest.raises(TypeError):
            analysis.type_of("x")


class TestAssignments:
    def test_declaration_mismatch(self):
        assert problems('let s: str = 1;') == [("type-mismatch", "expected 'str', got 'int'", 1, 14)]

    def test_coercion(self):
        assert problems("let f: float = 1;") == []
        assert problems("let i: int = 1.5;") == [("type-mismatch", "expected 'int', got 'float'", 1, 14)]

    def test_assignment_to_variable(self):
        assert messages('let n = 1; n = "x"; n = 2;') == ["expected 'int', got 'str'"]

    def test_assignment_to_field(self):
        source = 'struct P { x: int; } let p = P(1); p.x = 2; p.x = "no";'
        assert problems(source) == [("type-mismatch", "expected 'int', got 'str'", 1, 51)]

    def test_assignment_to_list_item(self):
        assert messages('let xs = [1]; xs[0] = 2; xs[0] = "s";') == ["expected 'int', got 'str'"]

    def test_unknown_is_compatible_with_everything(self):
        assert problems('fn f(a) { let s: str = a; let n: int = a; a = 1; }') == []


class TestOptional:
    def test_takes_nil_and_the_value(self):
        assert problems("let a: int? = nil; let b: int? = 1; a = 2; a = nil;") == []

    def test_does_not_take_another_type(self):
        assert messages('let a: int? = "s";') == ["expected 'int?', got 'str'"]

    def test_plain_type_does_not_take_nil(self):
        assert messages("let a: int = nil;") == ["expected 'int', got 'nil'"]

    def test_optional_to_plain(self):
        assert messages("let a: int? = 1; let b: int = a;") == ["expected 'int', got 'int?'"]

    def test_optional_to_optional(self):
        assert problems("let a: int? = 1; let b: float? = a; let c: int? = a;") == []

    def test_fields_through_an_optional(self):
        assert symbol_types("struct P { x: int; } let p: P? = nil; let v = p.x;")["v"] == "int"


class TestGenerics:
    def test_matching(self):
        assert problems("let a: list[int] = [1, 2]; let b: list[float] = [1.5];") == []

    def test_mismatch(self):
        assert messages('let a: list[str] = [1];') == ["expected 'list[str]', got 'list[int]'"]

    def test_empty_list_fits_any_list(self):
        assert problems("let a: list[str] = [];") == []

    def test_nested_and_two_arguments(self):
        source = "fn f(m: map[str, list[int]]) -> int { return m[\"k\"][0]; }"
        assert problems(source) == []
        assert symbol_types(source)["m"] == "map[str, list[int]]"

    def test_not_the_same_constructor(self):
        assert messages("fn f(a: set[int]) { let b: list[int] = a; }") == ["expected 'list[int]', got 'set[int]'"]


class TestIndexing:
    def test_list(self):
        assert symbol_types('let xs = ["a"]; let v = xs[0];')["v"] == "str"
        assert messages('let xs = [1]; xs["k"];') == ["expected an index of type 'int', got 'str'"]

    def test_map(self):
        source = "fn f(m: map[str, int]) { let v = m[\"k\"]; m[1]; }"
        assert symbol_types(source)["v"] == "int"
        assert messages(source) == ["expected an index of type 'str', got 'int'"]

    def test_string(self):
        assert symbol_types('let s = "abc"; let c = s[0];')["c"] == "str"

    def test_not_indexable(self):
        assert problems("let n = 1; n[0];") == [("not-indexable", "'int' cannot be indexed", 1, 12)]


class TestOperators:
    def test_bad_operands(self):
        assert problems('"a" + 1;') == [("bad-operand", "operator '+' cannot be applied to 'str' and 'int'", 1, 1)]

    def test_unary(self):
        assert messages('not 3; -"x"; not true; -1; -1.5;') == [
            "operator 'not' cannot be applied to 'int'",
            "operator '-' cannot be applied to 'str'",
        ]

    def test_division_coerces_to_float(self):
        assert symbol_types("let a = 1 / 2;")["a"] == "float"

    def test_same_type_on_both_sides(self):
        assert problems('1 == 1; "a" == "b"; 1 == 1.5; true != false;') == []
        assert messages('1 == "a";') == ["operator '==' cannot be applied to 'int' and 'str'"]

    def test_result_with_an_unknown_operand(self):
        source = "fn f(a) { let c = a < 1; let d = a + 1; let e = a == a; }"
        assert {k: v for k, v in symbol_types(source).items() if k in "cde"} == {"c": "bool", "d": None, "e": "bool"}

    def test_error_still_gives_a_result_when_every_row_agrees(self):
        # `<` is always bool, so the condition is not reported a second time
        assert messages('if 1 < "a" { }') == ["operator '<' cannot be applied to 'int' and 'str'"]

    def test_operator_not_in_the_table_is_not_judged(self):
        rules = make(operators={"+": [("int", "int", "int")]})
        assert problems('let a = 1 - "x"; let b = 1 + "x";', rules) == [
            ("bad-operand", "operator '+' cannot be applied to 'int' and 'str'", 1, 26)
        ]


class TestCalls:
    SRC = "fn add(a: int, b: int) -> int { return a + b; }\n"

    def test_arity(self):
        assert problems(self.SRC + "add(1); add(1, 2, 3);") == [
            ("arity", "add() takes 2 arguments, got 1", 2, 1),
            ("arity", "add() takes 2 arguments, got 3", 2, 9),
        ]

    def test_argument_types(self):
        assert problems(self.SRC + 'add(1, "two"); add(1.5, 2);') == [
            ("bad-argument", "argument 2 of add(): expected 'int', got 'str'", 2, 8),
            ("bad-argument", "argument 1 of add(): expected 'int', got 'float'", 2, 20),
        ]

    def test_result_is_usable_even_after_an_error(self):
        assert symbol_types(self.SRC + "let r = add(1);")["r"] == "int"

    def test_not_callable(self):
        assert problems("let n = 1; n();") == [("not-callable", "'n' is not callable: it is 'int'", 1, 12)]

    def test_arguments_are_checked_for_their_own_errors(self):
        assert messages(self.SRC + 'add("a" + 1, 2);') == ["operator '+' cannot be applied to 'str' and 'int'"]

    def test_builtins(self):
        assert problems('print(); print(1, "a", true); let n: int = len("abc"); len(1, 2);') == [
            ("arity", "len() takes 1 argument, got 2", 1, 56)
        ]

    def test_variadic_with_required_parameters(self):
        rules = make(builtins={"log": "fn(str, ...) -> void"}, scope_options={"builtins": ("log",)})
        assert messages('log("a"); log("a", 1, 2); log(1); log();', rules) == [
            "argument 1 of log(): expected 'str', got 'int'",
            "log() takes 1 argument, got 0",
        ]

    def test_function_values(self):
        source = self.SRC + "let f = add; let r = f(1, 2); f(1);"
        assert symbol_types(source)["f"] == "fn(int, int) -> int"
        assert messages(source) == ["f() takes 2 arguments, got 1"]


class TestReturns:
    def test_wrong_type(self):
        assert problems('fn f() -> int { return "x"; }') == [("bad-return", "expected to return 'int', got 'str'", 1, 24)]

    def test_missing_value(self):
        assert problems("fn f() -> int { return; }") == [("bad-return", "missing return value: expected 'int'", 1, 17)]

    def test_value_in_a_void_function(self):
        assert messages("fn f() -> void { return 1; }") == ["expected to return 'void', got 'int'"]
        assert problems("fn f() -> void { return; }") == []

    def test_unannotated_function_is_not_checked(self):
        assert problems('fn f() { return "x"; return; return 1; }') == []

    def test_nearest_function(self):
        source = 'fn outer() -> int { fn inner() -> str { return "s"; } return 1; }'
        assert problems(source) == []

    def test_coercion(self):
        assert problems("fn f() -> float { return 1; }") == []


class TestConditions:
    def test_must_be_bool(self):
        assert problems("if 1 { } while \"s\" { } if true { } while 1 < 2 { }") == [
            ("bad-condition", "expected a condition of type 'bool', got 'int'", 1, 4),
            ("bad-condition", "expected a condition of type 'bool', got 'str'", 1, 16),
        ]


class TestStructs:
    SRC = """struct Point { x: int; y: float; fn scale(k: float) -> Point { return Point(1, k); } }
"""

    def test_constructor(self):
        assert symbol_types(self.SRC + "let p = Point(1, 2.5);")["p"] == "Point"
        assert messages(self.SRC + 'Point(1); Point(1, "a");') == [
            "Point() takes 2 arguments, got 1",
            "argument 2 of Point(): expected 'float', got 'str'",
        ]

    def test_fields(self):
        source = self.SRC + "let p = Point(1, 2.0); let a = p.x; let b = p.y; p.z;"
        assert symbol_types(source)["a"] == "int" and symbol_types(source)["b"] == "float"
        assert problems(source) == [("no-field", "'Point' has no field 'z'", 2, 52)]

    def test_methods(self):
        source = self.SRC + 'let p = Point(1, 2.0); let q = p.scale(3.0); p.scale("a"); q.scale(1).x;'
        assert symbol_types(source)["q"] == "Point"
        assert messages(source) == ["argument 1 of p.scale(): expected 'float', got 'str'"]

    def test_as_a_type(self):
        source = self.SRC + "fn origin() -> Point { return Point(0, 0.0); } let p: Point = origin(); let n: int = origin();"
        assert messages(source) == ["expected 'int', got 'Point'"]

    def test_two_structs_are_different_types(self):
        source = "struct A { v: int; } struct B { v: int; } let a: A = B(1);"
        assert messages(source) == ["expected 'A', got 'B'"]

    def test_struct_in_a_list(self):
        source = self.SRC + "let ps: list[Point] = [Point(1, 1.0)]; let x = ps[0].x;"
        assert problems(source) == [] and symbol_types(source)["x"] == "int"

    def test_the_struct_name_is_a_type_value(self):
        assert symbol_types(self.SRC)["Point"] == "type[Point]"
        assert messages(self.SRC + "let n: int = Point;") == ["expected 'int', got 'type[Point]'"]

    def test_field_of_a_non_struct(self):
        assert problems("let n = 1; n.x;") == [("no-field", "'int' has no field 'x'", 1, 14)]


class TestUnknownTypes:
    def test_reported_once_as_an_undefined_name(self):
        assert problems("let a: Nope = 1;") == [("undefined-name", "undefined name 'Nope'", 1, 8)]

    def test_reported_by_types_when_names_do_not_cover_type_names(self):
        rules = make(scope_options={"use": "ident"})
        assert problems("let a: Nope = 1; fn f(b: Nope) { }", rules) == [
            ("unknown-type", "unknown type 'Nope'", 1, 8),
            ("unknown-type", "unknown type 'Nope'", 1, 26),
        ]

    def test_a_variable_is_not_a_type(self):
        assert messages("let v = 1; let a: v = 2;") == ["unknown type 'v'"]

    def test_unknown_and_any_are_not_checked(self):
        assert problems('let a: unknown = 1; let b: any = "s"; let c: int = a;', make(basic=typed.TYPES["basic"] + ("unknown", "any"))) == []

    def test_basic_type_names_are_types(self):
        # like a struct's name, a basic type's name stands for the type
        types_of = {s.name: s.type for s in RULES.analyze("struct P { a: int; }").symbols}
        assert types_of["int"] == "type[int]" and types_of["float"] == "type[float]"
        assert types_of["P"] == "type[P]"


class TestProject:
    LIB = "struct Point { x: int; y: int; }\nfn make(v: int) -> Point { return Point(v, v); }\nlet limit: int = 10;\n"

    def test_an_imported_name_used_as_a_type_without_its_definition(self):
        # checked alone, or with the module missing: Point may well be a type
        main = "from lib import Point;\nfn f(p: Point) -> int { return 1; }\n"
        assert RULES.check(main) == []
        project = RULES.analyze_project({"main": main})
        assert [d.code for d in project.file("main").diagnostics] == ["no-module"]
        # a name known not to be a type still is reported
        assert [d.code for d in RULES.check("let x = 1;\nlet y: x = 2;\n")] == ["unknown-type"]

    def test_types_cross_named_imports(self):
        project = RULES.analyze_project(
            {"lib": self.LIB, "main": 'from lib import make, limit, Point;\nlet p = make(limit);\nlet q: Point = p;\nlet s: str = p.x;\nmake("a");'}
        )
        assert [(d.code, d.message, d.line) for d in project.file("main").diagnostics] == [
            ("type-mismatch", "expected 'str', got 'int'", 4),
            ("bad-argument", "argument 1 of make(): expected 'int', got 'str'", 5),
        ]
        main = project.file("main")
        assert {s.name: s.type for s in main.symbols if s.name in ("p", "make", "Point")} == {
            "p": "Point",
            "make": "fn(int) -> Point",
            "Point": "type[Point]",
        }

    def test_types_cross_module_imports(self):
        project = RULES.analyze_project({"lib": self.LIB, "main": 'import lib;\nlet p = lib.make(1);\nlet n: str = lib.limit;\nlet q: int = p.y;'})
        assert [(d.message, d.line) for d in project.file("main").diagnostics] == [("expected 'str', got 'int'", 3)]

    def test_same_struct_from_two_files_is_one_type(self):
        project = RULES.analyze_project(
            {
                "lib": self.LIB,
                "a": "from lib import Point;\nfn one() -> Point { return Point(1, 1); }",
                "b": "from lib import Point;\nfrom a import one;\nlet p: Point = one();",
            }
        )
        assert project.ok

    def test_cyclic_imports(self):
        project = RULES.analyze_project(
            {
                "a": "from b import g;\nfn f() -> int { return g(); }\nlet x: str = g();",
                "b": "from a import f;\nfn g() -> int { return f(); }",
            }
        )
        assert [d.message for d in project.file("a").diagnostics] == ["expected 'str', got 'int'"]
        assert project.file("b").diagnostics == []

    def test_analyses_outlive_the_project_and_the_rules(self):
        rules = make()
        project = rules.analyze_project({"lib": self.LIB, "main": "from lib import make;\nlet p = make(1);"})
        main = project.file("main")
        del project, rules
        gc.collect()
        assert {s.name: s.type for s in main.symbols if not s.builtin} == {"make": "fn(int) -> Point", "p": "Point"}
        assert main.type_of(main.tree.root.find("call_args")[0]) == "Point"

    def test_one_file_alone_does_not_know_imported_types(self):
        assert problems('from lib import make;\nlet s: str = make(1);') == []


class TestCustomRulesSeeTypes:
    def test_ctx_type_of(self):
        rules = make()
        seen = []
        rules.add("let_stmt", lambda node, ctx: seen.append((node.get("name").text(), ctx.type_of(node.get("value")))))
        rules.check('let a = 1; let b = [a]; let c = b[0] < 2;')
        assert seen == [("a", "int"), ("b", "list[int]"), ("c", "bool")]


class TestOptions:
    def test_needs_a_scopes_rule(self):
        with pytest.raises(ValueError, match="needs a scopes"):
            Rules(PARSER, [types(basic=("int",))])
        with pytest.raises(ValueError, match="no scopes\\(\\) rule has that namespace"):
            Rules(PARSER, [scopes(**typed.SCOPES), types(namespace="other")])

    def test_basic_types_are_known_names(self):
        assert problems("let a: int = 1; let b: float = 1.5;") == []

    def test_severity_codes_and_ignore(self):
        rules = make(severity="warning", codes={"mismatch": "T001"}, ignore=("condition",))
        ds = rules.check('let s: str = 1; if 1 { }')
        assert [(d.severity, d.code) for d in ds] == [("warning", "T001")]

    def test_labels(self):
        with pytest.raises(ValueError, match="unknown role 'nope'"):
            make(labels={"nope": "x"})
        # reading the callee through a label the grammar doesn't have: calls are not judged
        assert problems("let n = 1; n();", make(labels={"target": "missing"})) == []

    @pytest.mark.parametrize(
        "options, exc, match",
        [
            ({"literals": {"int_lit": "list["}}, ValueError, "not a type"),
            ({"literals": "x"}, TypeError, "dict"),
            ({"operators": {"+": [("int",)]}}, ValueError, "a row is"),
            ({"operators": {"+": "int"}}, TypeError, "list of rows"),
            ({"operators": {"+": [("int", "int", "in t")]}}, ValueError, "not a type"),
            ({"coerce": {"int": "fl oat"}}, ValueError, "not a type"),
            ({"builtins": {"print": "fn("}}, ValueError, "not a type"),
            ({"codes": {"nope": "X"}}, ValueError, "unknown kind"),
            ({"ignore": ("nope",)}, ValueError, "unknown kind"),
            ({"severity": "fatal"}, ValueError, "severity"),
            ({"variables": "Nope"}, ValueError, "no rule or class"),
        ],
    )
    def test_bad_options(self, options, exc, match):
        with pytest.raises(exc, match=match):
            make(**options)

    def test_names_of_the_types_the_checker_needs(self):
        grammar_types = dict(
            basic=("Int", "Float", "String", "Boolean", "Unit", "Null"),
            names={"bool": "Boolean", "int": "Int", "str": "String", "void": "Unit", "nil": "Null"},
            coerce={"Int": "Float"},
            literals={"int_lit": "Int", "float_lit": "Float", "string": "String", "bool_lit": "Boolean", "nil_lit": "Null"},
            operators={"<": [("Int", "Int", "Boolean")]},
            builtins={"print": "fn(...)", "len": "fn(any) -> Int"},
        )
        rules = make(**grammar_types)
        source = (
            'if 1 { } if 1 < 2 { } let xs = [1]; xs["a"]; let c = "abc"[0]; let o: Int? = nil;\n'
            "fn f() -> Int { return; } fn g() -> Unit { return; } let p: Int = print();"
        )
        assert messages(source, rules) == [
            "expected a condition of type 'Boolean', got 'Int'",
            "expected an index of type 'Int', got 'String'",
            "missing return value: expected 'Int'",
            "expected 'Int', got 'Unit'",
        ]
        assert symbol_types(source, rules)["c"] == "String"
        with pytest.raises(ValueError, match="unknown type 'number'"):
            make(names={"number": "Int"})
        with pytest.raises(TypeError, match="dict"):
            make(names=("bool",))

    def test_coercions_chain_and_may_go_in_circles(self):
        chain = make(basic=typed.TYPES["basic"] + ("number",), coerce={"int": "float", "float": "number"})
        assert problems("fn f(n: number) { } f(1); f(1.5); let i: int = 1.5;", chain)[0][1] == "expected 'int', got 'float'"
        assert len(problems("fn f(n: number) { } f(1); f(1.5); let i: int = 1.5;", chain)) == 1
        circle = make(coerce={"int": "float", "float": "int"})
        assert messages('let i: int = 1.5; let f: float = 1; let s: str = 1;', circle) == ["expected 'str', got 'int'"]

    def test_function_types_in_options(self):
        rules = make(builtins={"apply": "fn(fn(int) -> int, int) -> int"}, scope_options={"builtins": ("apply",)})
        source = "fn inc(v: int) -> int { return v + 1; } fn name(v: str) -> str { return v; } let r = apply(inc, 1); apply(name, 1);"
        assert messages(source, rules) == ["argument 1 of apply(): expected 'fn(int) -> int', got 'fn(str) -> str'"]


class TestDepth:
    """Types that depend on one another through long chains: no recursion limit, no stack to run out of."""

    UNORDERED = make(scope_options={"ordered": False, "after": ()})

    def test_long_chain_in_one_file(self):
        n = 20000
        source = "fn f() { " + "".join(f"let a{i} = a{i + 1} + 1; " for i in range(n)) + f"let s: str = a0; }} let a{n} = 1;"
        assert messages(source, self.UNORDERED) == ["expected 'str', got 'int'"]

    def test_long_chain_across_files(self):
        n = 3000
        files = {f"m{i}": (f"from m{i - 1} import v{i - 1};\nlet v{i} = v{i - 1};" if i else "let v0 = 1;") for i in reversed(range(n))}
        files["main"] = f"from m{n - 1} import v{n - 1};\nlet s: str = v{n - 1};"
        project = RULES.analyze_project(files)
        assert [(d.message, d.line) for d in project.file("main").diagnostics] == [("expected 'str', got 'int'", 2)]
        assert all(project.file(key).ok for key in files if key != "main")
        assert project.file("m1").symbols[-1].type == "int"

    def test_errors_along_a_chain_are_reported_once(self):
        n = 300
        source = "fn f() { " + "".join(f'let a{i} = [a{i + 1}, "x", 1.5]; ' for i in range(n)) + f"}} let a{n} = 1;"
        found = problems(source, self.UNORDERED)
        assert len(found) == len(set(found)) == 2 * n - 1
        # the last list is [int, str, float]: only the str doesn't fit
        assert [m for _, m, _, _ in found if "'int'" in m] == ["expected an item of type 'int', got 'str'"]

    # Deeper than the checker's own recursion goes (100), and no deeper than
    # the parser gets on a small stack: that one recurses per nesting level
    @pytest.mark.parametrize(
        "source",
        [
            "let x: str = " + "(" * 300 + "1" + ")" * 300 + ";",
            "let x: str = " + "-" * 1000 + "1;",
            "fn f(a: int) -> int { return a; } let x: str = " + "f(" * 300 + "1" + ")" * 300 + ";",
        ],
        ids=["parentheses", "unary", "calls"],
    )
    def test_deep_expressions(self, source):
        assert messages(source) == ["expected 'str', got 'int'"]

    def test_deep_types(self):
        depth = 400
        nested = "list[" * depth + "int" + "]" * depth
        assert problems(f"let x: {nested} = {'[' * depth}1{']' * depth};") == []
        (message,) = messages(f"let x: {nested} = {'[' * depth}\"s\"{']' * depth};")
        assert message.startswith("expected 'list[list[") and message.endswith("str" + "]" * depth + "'")
        symbol = RULES.analyze(f"let x: {nested} = 1;").symbols[-1]
        assert symbol.name == "x" and isinstance(symbol.type, str)

    def test_small_stack(self):
        import threading

        n = 5000
        source = "fn f() { " + "".join(f"let a{i} = a{i + 1} + 1; " for i in range(n)) + f"let s: str = a0; }} let a{n} = 1;"
        out = []
        old = threading.stack_size(512 * 1024)
        try:
            thread = threading.Thread(target=lambda: out.append(messages(source, self.UNORDERED)))
            thread.start()
            thread.join()
        finally:
            threading.stack_size(old)
        assert out == [["expected 'str', got 'int'"]]

    @pytest.mark.parametrize(
        "source",
        [
            "let x = " + "(" * 1_000_000 + "1" + ")" * 1_000_000 + ";",
            "let x = " + "[" * 1_000_000 + "1" + "]" * 1_000_000 + ";",
            "fn f() { " + "if true { " * 500_000 + "}" * 500_000 + " }",
        ],
        ids=["parentheses", "lists", "blocks"],
    )
    def test_input_too_deep_to_parse_is_a_parse_error(self, source):
        # zgram stops at the native stack's limit: an error, not a crash
        import zgram

        with pytest.raises(zgram.ParseError, match="nested too deeply"):
            RULES.check(source)
        with pytest.raises(zgram.ParseError, match="nested too deeply"):
            RULES.analyze_project({"deep": source, "fine": "let y = 1;"})
        assert messages("let y: str = 1;") == ["expected 'str', got 'int'"]

    def test_type_text_in_options_nests_only_so_deep(self):
        with pytest.raises(ValueError, match="builtins: 'list"):
            make(builtins={"print": "list[" * 5000 + "int" + "]" * 5000})


class TestScale:
    def test_many_files(self):
        import time

        def timed(n):
            files = {f"m{i}": (f"from m{i - 1} import v{i - 1};\nlet v{i}: int = v{i - 1};" if i else "let v0 = 1;") for i in range(n)}
            best = float("inf")
            for _ in range(3):
                start = time.perf_counter()
                assert RULES.analyze_project(files).ok
                best = min(best, time.perf_counter() - start)
            return best

        timed(200)
        # four times the files: not sixteen times the time
        assert timed(8000) < 11 * max(timed(2000), 0.002)

    def test_many_declarations(self):
        lines = ["fn f(a: int, b: int) -> int { let c = a + b; return c * 2; }"]
        lines += [f"let v{'abcdefghij'[i % 10]}{'abcdefghij'[i // 10 % 10]}{'abcdefghij'[i // 100]} = f({i}, {i}) + {i};" for i in range(1000)]
        lines.append('let bad: str = f(1, 2);')
        ds = RULES.check("\n".join(lines))
        assert [(d.message, d.line) for d in ds] == [("expected 'str', got 'int'", 1002)]
