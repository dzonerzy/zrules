"""Projects large enough to be checked on several threads give exactly the results of one."""

import os

import pytest
from zrules import Rules, flow, scopes, types

import typed

MODULES = 160


def module(m):
    """A module that imports the previous one's struct and functions, with
    a known set of mistakes in every fifth module."""
    lines = []
    if m:
        lines.append(f"from m{m - 1} import Point{m - 1}, make{m - 1}, total{m - 1};")
    lines.append(f"struct Point{m} {{ x: int; y: float; fn sum() -> float {{ return x + y; }} }}")
    lines.append(f"fn make{m}(v: int) -> Point{m} {{ return Point{m}(v, 1.5); }}")
    lines.append(f"fn total{m}(ps: list[Point{m}]) -> float {{ let t = 0.0; let i = 0; while i < len(ps) {{ t = t + ps[i].sum(); i = i + 1; }} return t; }}")
    # Enough code that the whole project takes the parallel path
    for i in range(60):
        lines.append(
            f"fn f{m}_{i}(a: int, b: int) -> int {{ let c: int; if a < b {{ c = a + b; }} else {{ c = a - b; }} "
            f"while c < {i} {{ c = c * 2; if c > 1000 {{ break; }} }} return c; }}"
        )
    if m:
        lines.append(f"let p{m}: Point{m - 1} = make{m - 1}({m});")
        lines.append(f"let s{m}: float = total{m - 1}([p{m}]);")
    if m % 5 == 4:
        lines.append(f"let bad{m}: str = make{m - 1}(1).x;")  # type-mismatch across the import
        lines.append(f"fn g{m}() -> int {{ let u: int; if true {{ u = 1; }} return u; }}")  # maybe unassigned
        lines.append(f"fn h{m}() -> int {{ return 1; print(2); }}")  # unreachable
        lines.append(f"make{m - 1}(\"x\");")  # bad-argument across the import
    return "\n".join(lines)


EXPECTED = {
    f"m{m}": (["type-mismatch", "unassigned", "unreachable", "bad-argument"] if m % 5 == 4 else [])
    for m in range(MODULES)
}


@pytest.fixture(scope="module")
def rules():
    return Rules(typed.PARSER, [scopes(**typed.SCOPES), types(**typed.TYPES), flow(**typed.FLOW)])


@pytest.fixture(scope="module")
def project_trees():
    trees = {f"m{m}": typed.PARSER.parse_tree(module(m)) for m in range(MODULES)}
    # Enough for several threads (one per 100,000 nodes)
    assert sum(len(t) for t in trees.values()) > 200_000
    return trees


def outcome(project):
    return {
        key: sorted(d.code for d in project.file(key).diagnostics)
        for key in project.files
    }


def test_results(rules, project_trees):
    project = rules.analyze_project(project_trees)
    assert outcome(project) == {k: sorted(v) for k, v in EXPECTED.items()}
    last = project.file(f"m{MODULES - 1}")
    types_of = {s.name: s.type for s in last.symbols if not s.builtin}
    assert types_of[f"p{MODULES - 1}"] == f"Point{MODULES - 2}"
    assert types_of[f"make{MODULES - 2}"] == f"fn(int) -> Point{MODULES - 2}"
    assert types_of[f"s{MODULES - 1}"] == "float"


def test_the_same_every_time(rules, project_trees):
    first = rules.analyze_project(project_trees)
    expected = outcome(first)
    messages = {k: [d.render("", k) for d in first.file(k).diagnostics] for k in first.files}
    for _ in range(15):
        again = rules.analyze_project(project_trees)
        assert outcome(again) == expected
        assert {k: [d.render("", k) for d in again.file(k).diagnostics] for k in again.files} == messages


def test_same_as_one_file_at_a_time_where_nothing_is_imported(rules, project_trees):
    # Without imports every file stands alone: the parallel project check
    # must agree with checking each file by itself
    standalone = {k: typed.PARSER.parse_tree(module(0).replace("Point0", f"Q{i}")) for i, k in enumerate(project_trees)}
    project = rules.analyze_project(standalone)
    for key, tree in standalone.items():
        assert [(d.line, d.column, d.code) for d in project.file(key).diagnostics] == [(d.line, d.column, d.code) for d in rules.check(tree)]


def test_analyses_are_independent_afterwards(rules, project_trees):
    project = rules.analyze_project(project_trees)
    files = [project.file(k) for k in project.files]
    del project
    for f in files:
        assert all(isinstance(s.type, (str, type(None))) for s in f.symbols)


@pytest.mark.skipif(os.cpu_count() == 1, reason="one CPU: nothing runs in parallel")
def test_faster_than_one_file_after_another(rules, project_trees):
    import time

    def best(fn):
        times = []
        for _ in range(3):
            start = time.perf_counter()
            fn()
            times.append(time.perf_counter() - start)
        return min(times)

    one_by_one = best(lambda: [rules.check(t) for t in project_trees.values()])
    together = best(lambda: rules.analyze_project(project_trees))
    # (checking one at a time can't see the imports, so does less)
    assert together < one_by_one * 1.5
