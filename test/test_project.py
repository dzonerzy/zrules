"""analyze_project(): several files, with imports between them."""

import gc

import pytest
import zgram
from zrules import Rules, forbid, scopes


@pytest.fixture
def rules(parser):
    return make(parser)


def make(parser, **kwargs):
    options = dict(
        scope=("Program", "FuncDef"),
        define=("Let > .name", "FuncDef > .params"),
        define_outer="FuncDef > .name",
        use="Name",
        hoist="FuncDef > .name",
        members="Member",
        imports=("Import", "FromImport"),
        import_all="FromImport:has(> star)",
    )
    options.update(kwargs)
    return Rules(parser, [scopes(**options)])


def messages(project):
    return {key: [(d.code, d.message, d.line, d.column) for d in ds] for key, ds in project.diagnostics.items() if ds}


UTIL = "fn helper(x) { return x; }\nlet limit = 10;\nfn other() { let local = 1; }\n"


class TestNamedImports:
    def test_resolves(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import helper, limit;\nhelper(limit);"})
        assert project.ok and messages(project) == {}

    def test_name_the_module_does_not_have(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import helper, nope;\nhelper(nope);"})
        assert messages(project) == {"main": [("no-export", "module 'util' has no 'nope'", 1, 26)]}

    def test_only_top_level_names_are_exported(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import local, x;"})
        assert [m[1] for m in messages(project)["main"]] == ["module 'util' has no 'local'", "module 'util' has no 'x'"]

    def test_alias(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import helper as h;\nh(1); helper(1);"})
        assert messages(project) == {"main": [("undefined-name", "undefined name 'helper'", 2, 7)]}

    def test_alias_of_a_missing_name(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import nope as n; n;"})
        assert messages(project) == {"main": [("no-export", "module 'util' has no 'nope'", 1, 18)]}

    def test_imported_name_is_visible_after_the_import(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "helper(1);\nfrom util import helper;"})
        assert messages(project) == {"main": [("undefined-name", "undefined name 'helper'", 1, 1)]}

    def test_conflict_with_a_local_definition(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import limit;\nlet limit = 1;"})
        assert [m[0] for m in messages(project)["main"]] == ["redefined-name"]

    def test_origin(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import helper as h;\nh(1);"})
        main, util = project.file("main"), project.file("util")
        local = main.at(len("from util import helper as "))
        assert (local.name, local.builtin, local.module) == ("h", False, None)
        file, node = local.origin
        assert file == "util" and util.tree.node(node).text() == "helper"
        real = project.origin(local)
        assert real is util.resolve(node) and real.name == "helper" and real.origin is None
        assert project.origin(real) is real
        assert len(local.uses) == 1


class TestModuleImports:
    def test_member_access(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "import util;\nutil.helper; print_it(util.limit);\nfn print_it(v) {}"})
        assert project.ok and messages(project) == {}

    def test_missing_member(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "import util;\nutil.nope; util.local;"})
        assert messages(project) == {
            "main": [("no-member", "'util' has no member 'nope'", 2, 6), ("no-member", "'util' has no member 'local'", 2, 17)]
        }

    def test_alias(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "import util as u;\nu.helper; util.helper;"})
        assert messages(project) == {"main": [("undefined-name", "undefined name 'util'", 2, 11)]}

    def test_members_need_the_qualifier(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "import util;\nhelper(1);"})
        assert [m[1] for m in messages(project)["main"]] == ["undefined name 'helper'"]

    def test_module_symbol(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "import util as u;\nu.helper; u.helper; u.limit;"})
        main, util = project.file("main"), project.file("util")
        module = main.at(len("import util as "))
        assert (module.name, module.module, module.origin) == ("u", "util", None)
        accesses = main.tree.root.find("member")
        helper = main.resolve(accesses[0])
        assert helper.name == "helper" and helper.origin[0] == "util" and helper.node is None and not helper.builtin
        assert main.resolve(accesses[1]) is helper and main.resolve(accesses[0].get("name")) is helper
        assert len(helper.uses) == 2
        assert project.origin(helper) is util.symbols[0]
        assert main.resolve(accesses[2]).name == "limit"


class TestWildcard:
    def test_everything_exported_is_visible(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import *;\nhelper(limit); other(); local;"})
        assert messages(project) == {"main": [("undefined-name", "undefined name 'local'", 2, 25)]}

    def test_local_definitions_win(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import *;\nlet limit = 1; limit;"})
        main = project.file("main")
        assert project.ok
        assert main.resolve(main.tree.root.find("ident")[-1]).origin is None

    def test_origin(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import *;\nhelper(1);"})
        helper = project.file("main").resolve(project.file("main").tree.root.find("call")[0].get("name"))
        assert helper.origin[0] == "util" and project.origin(helper).span == (3, 9)


class TestProject:
    def test_missing_module(self, rules):
        project = rules.analyze_project({"main": "import nowhere;\nfrom gone import a;\nfrom lost import *;\na; anything;"})
        assert messages(project) == {
            "main": [
                ("no-module", "module 'nowhere' not found", 1, 8),
                ("no-module", "module 'gone' not found", 2, 6),
                ("no-module", "module 'lost' not found", 3, 6),
            ]
        }
        assert not project.ok

    def test_cycles(self, rules):
        project = rules.analyze_project(
            {
                "a": "from b import pong;\nfn ping() { return pong(); }",
                "b": "from a import ping;\nfn pong() { return ping(); }",
            }
        )
        assert project.ok and messages(project) == {}

    def test_reexport(self, rules):
        project = rules.analyze_project(
            {"base": "fn f() {}", "mid": "from base import f;", "top": "from mid import f;\nf();"}
        )
        assert project.ok
        f = project.file("top").at(len("from mid import "))
        assert f.origin[0] == "mid"
        real = project.origin(f)
        assert real is project.file("base").symbols[0]

    def test_exports_option(self, parser):
        rules = make(parser, exports="FuncDef > .name")
        project = rules.analyze_project({"util": UTIL, "main": "from util import helper, limit;"})
        assert messages(project) == {"main": [("no-export", "module 'util' has no 'limit'", 1, 26)]}

    def test_resolver(self, rules):
        calls = []

        def resolve(module, importing):
            calls.append((module, importing))
            return {"util": "lib/util.z"}.get(module)

        project = rules.analyze_project(
            {"lib/util.z": UTIL, "app.z": "import util;\nutil.helper;\nimport other;"}, resolve=resolve
        )
        assert calls == [("util", "app.z"), ("other", "app.z")]
        assert messages(project) == {"app.z": [("no-module", "module 'other' not found", 3, 8)]}
        assert project.file("app.z").at(7).module == "lib/util.z"

    def test_resolver_returning_an_unknown_key(self, rules):
        project = rules.analyze_project({"main": "import util;"}, resolve=lambda module, importing: "not-a-file")
        assert [m[0] for m in messages(project)["main"]] == ["no-module"]

    def test_resolver_exception_propagates(self, rules):
        def boom(module, importing):
            raise LookupError(module)

        with pytest.raises(LookupError, match="util"):
            rules.analyze_project({"main": "import util;"}, resolve=boom)

    def test_non_string_keys(self, rules):
        project = rules.analyze_project({1: UTIL, 2: "import util;\nutil.helper;"}, resolve=lambda module, importing: 1)
        assert project.ok and project.files == [1, 2]
        assert project.file(2).at(7).module == 1

    def test_levels_and_messages(self, parser):
        rules = make(parser, on_no_module="warning", on_no_export="ignore", messages={"no_module": "cannot find {text}"}, codes={"no_module": "E9"})
        project = rules.analyze_project({"util": UTIL, "main": "import gone;\nfrom util import nope;"})
        assert project.ok
        (d,) = project.file("main").diagnostics
        assert (d.severity, d.code, d.message) == ("warning", "E9", "cannot find gone")

    def test_project_object(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "import util;"})
        assert type(project).__name__ == "Project"
        assert len(project) == 2 and project.files == ["util", "main"]
        assert type(project.file("main")).__name__ == "Analysis"
        assert project.diagnostics == {"util": [], "main": []}
        with pytest.raises(KeyError):
            project.file("nope")

    def test_trees_and_text_mixed(self, parser, rules):
        tree = parser.parse_tree(UTIL)
        project = rules.analyze_project({"util": tree, "main": "import util;\nutil.limit;"})
        assert project.ok and project.file("util").tree is tree

    def test_other_rules_run_per_file(self, parser):
        rules = Rules(parser, [forbid("Break", message="no break"), scopes(scope="Program", define="Let > .name", use="Name", imports="Import")])
        seen = []
        rules.add("Let", lambda node, ctx: seen.append(node.text()))
        project = rules.analyze_project({"a": "break; let x = 1;", "b": "let y = 2;"})
        assert messages(project) == {"a": [("forbid", "no break", 1, 1)]}
        assert seen == ["let x = 1;", "let y = 2;"]

    def test_syntax_error_in_one_file(self, rules):
        with pytest.raises(zgram.ParseError):
            rules.analyze_project({"util": UTIL, "main": "import ;"})

    @pytest.mark.parametrize("files", [[], "x", 5, None])
    def test_files_must_be_a_dict(self, rules, files):
        with pytest.raises(TypeError):
            rules.analyze_project(files)

    def test_resolve_must_be_callable(self, rules):
        with pytest.raises(TypeError, match="callable"):
            rules.analyze_project({}, resolve=5)

    def test_empty_project(self, rules):
        project = rules.analyze_project({})
        assert len(project) == 0 and project.ok and project.files == []

    def test_analyses_outlive_the_project(self, rules):
        project = rules.analyze_project({"util": UTIL, "main": "from util import helper;\nhelper(1);"})
        main = project.file("main")
        del project
        gc.collect()
        symbol = main.at(len("from util import "))
        assert symbol.origin[0] == "util"

    def test_many_files(self, rules):
        files = {f"m{'abcdefghij'[i]}": f"fn f{'abcdefghij'[i]}() {{}}" for i in range(10)}
        files["main"] = "".join(f"import m{c};\nm{c}.f{c};\n" for c in "abcdefghij") + "ma.fb;"
        project = rules.analyze_project(files)
        assert messages(project) == {"main": [("no-member", "'ma' has no member 'fb'", 21, 4)]}


class TestOneFileAlone:
    """check() and analyze() can't follow imports: they assume the best."""

    def test_named_imports_are_plain_definitions(self, rules):
        assert rules.check("from util import helper;\nhelper(1);") == []

    def test_module_members_are_not_judged(self, rules):
        assert rules.check("import util;\nutil.anything;") == []

    def test_wildcard_silences_undefined_names(self, rules):
        assert rules.check("from util import *;\nanything(1);") == []
        assert [d.message for d in rules.check("anything(1);")] == ["undefined name 'anything'"]

    def test_symbols_have_no_origin(self, rules):
        analysis = rules.analyze("import util as u;\nfrom util import helper;")
        assert [(s.name, s.origin, s.module) for s in analysis.symbols] == [("u", None, None), ("helper", None, None)]


class TestOptions:
    def test_import_labels(self, parser):
        with pytest.raises(ValueError, match="no label 'source'"):
            make(parser, import_labels=("source", "names", "alias"))
        with pytest.raises(ValueError, match="three labels"):
            make(parser, import_labels=("module",))

    def test_imports_without_the_names_label(self, parser):
        # a grammar with only `import m;` has no label for names: that's fine
        rules = make(parser, imports="Import", import_all=(), import_labels=("module", "nothing", "alias"))
        project = rules.analyze_project({"util": UTIL, "main": "import util;\nutil.helper;"})
        assert project.ok
