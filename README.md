# zrules

**Static rules over [zgram](https://github.com/dzonerzy/zgram) parse trees.**

zgram tells you whether a text is well-formed. zrules tells you whether it is *valid*: `break` only inside a loop, no duplicate parameters, `len()` takes one argument. You write each check as one line; zrules runs them natively over zgram's parse tree and reports every violation as a `zgram.Diagnostic`.

It covers five levels of checking: one-line structural rules, name resolution with scopes (which also gives you a symbol table, within a file or across a project), type checking, control flow (unreachable code, missing returns, variables used before they have a value), and custom rules written as Python functions. Part of zsuite (zgram, zrules, zrun, zlsp).

```python
import zgram
from zrules import Rules, inside, unique, forbid, require, count

parser = zgram.compile(GRAMMAR)          # your language's grammar

rules = Rules(parser, [
    inside("Break", within="While", stop_at="FuncDef",
           code="break-outside-loop", message="'break' outside loop"),
    inside("Return", within="FuncDef", message="'return' outside function"),
    unique("FuncDef > .params", message="duplicate parameter '{text}'"),
    count("Call[name=len] > .args", exactly=1,
          message="len() takes one argument, got {count}"),
])

source = "fn f(a, a) { break; }"
for d in rules.check(source):
    print(d.render(source, "program.z"))
```

```
program.z:1:9: error: duplicate parameter 'a' [unique]
    1 | fn f(a, a) { break; }
      |         ^
program.z:1:6: note: first one is here
    1 | fn f(a, a) { break; }
      |      ^
program.z:1:14: error: 'break' outside loop [break-outside-loop]
    1 | fn f(a, a) { break; }
      |              ^^^^^^
```

Every option, class member and diagnostic code is listed in the [reference](docs/reference.md).

## Installation

```bash
pip install zrules
```

Requires `zgram-py` 0.2 or newer. Wheels cover CPython 3.10+ on x86_64 Linux and Windows.

## Selectors

A selector picks nodes of the parse tree, in the spirit of CSS.

| Selector | Matches |
|----------|---------|
| `call` | every node of rule `call` |
| `Call` | every node of a rule mapped to class `Call` (`-> Call` in the grammar) |
| `*` | any node |
| `.cond` | a node labelled `cond` in its parent (`cond:expr` in the grammar) |
| `If.then` | both: that rule or class, and that label |
| `call[name=len]` | a `call` with a direct child labelled `name` whose text is `len` |
| `call > ident` | an `ident` that is a direct child of a `call` |
| `funcdef ident` | an `ident` anywhere inside a `funcdef` |

| `call:not(.value)` | a `call` that is not labelled `value` (any single part can be negated) |
| `call:has(> .args)` | a `call` with a child labelled `args`; `:has(x)` without `>` looks at all descendants |
| `.params:nth(2)` | the second `.params` among its siblings; also `:first` and `:last` |
| `let + expr` | an `expr` right after a `let` sibling; `let ~ expr`: anywhere after it |
| `break, return` | either one: wherever a selector is accepted, so is a comma-separated list or a sequence of selectors |

A name is a grammar rule name or a class name; a class name stands for every rule mapped to it, so `BinOp` covers `sum`, `product` and `compare` alike. Unknown names and labels are rejected when the rules are compiled, not silently ignored. Remember that `@silent` rules make no nodes and cannot be selected. A selector has at most 16 parts.

## Rules

Every rule takes `message`, `code` and `severity` (`"error"`, `"warning"` or `"note"`). A message can use these placeholders:

| | |
|---|---|
| `{text}` | the flagged node's text |
| `{rule}`, `{field}` | its rule name and its label (empty without one) |
| `{parent}` | its parent's rule name |
| `{count}`, `{min}`, `{max}` | for `count`: the number found and the allowed range |

| Rule | Reports |
|------|---------|
| `inside(selector, within, stop_at=None)` | a match with no ancestor matching `within` (a selector or several), looking no further up than an ancestor matching `stop_at` |
| `unique(selector, within=None)` | a match whose text was already seen in its group; the first occurrence is attached as a note |
| `forbid(selector)` | every match |
| `require(selector)` | a node matching all but the last part of the selector with no match of the whole selector: `require("funcdef > block")` |
| `count(selector, exactly=None, min=None, max=None, within=None)` | a group with the wrong number of matches |

For `unique` and `count`, a group is the nearest ancestor matching `within`: `unique("Let > .name, .params", within="FuncDef")` makes variables and parameters unique per function. Without `within`, the group is the node the selector's first part matched (`unique("FuncDef > .params")`), or the whole tree for a one-part selector.

## Scopes and names

`scopes()` resolves names: it reports undefined and redefined names, and records which definition every use refers to.

```python
scopes(
    scope=("Program", "FuncDef"),                 # nodes that open a scope
    define=("Let > .name", "FuncDef > .params"),  # nodes whose text is a name defined in the scope around them
    define_outer="FuncDef > .name",               # ... defined in the scope outside that one
    use="Name",                                   # nodes that must resolve to a definition
    hoist="FuncDef > .name",                      # definitions visible before their position
    after="Let > .name",                          # definitions visible only after their declaration ends
    builtins=("print", "len"),
)
```

- **Scopes nest.** A definition belongs to the nearest scope node above it; text outside every scope node is the global scope. A use is resolved through the scopes above it, innermost first.
- **`define_outer`** is for a name that sits inside the node whose scope it does not belong to: a function's own name is inside the `FuncDef` node but is defined in the scope around the function.
- **Order.** Within one scope a definition is visible from the end of its name on, so `print(x); let x = 1;` is an error. `hoist` lifts that for definitions such as functions; `after` tightens it to the end of the parent node, so `let a = a;` does not see the new `a`. A use in a nested scope sees every definition of the scopes around it, wherever it appears. `ordered=False` turns ordering off.
- **`outside`** is for a part of a scope node that is evaluated before the scope exists: the bounds of `for i = i, 10`, a parameter's default value. Names in a node selected by `outside="For > .bounds"` are looked up from the scope outside the one they are written in.
- **A node that is a definition is not also a use**, so `use="Name"` can simply select every name.

| Option | Default | |
|--------|---------|---|
| `on_undefined` | `"error"` | a use that resolves to nothing |
| `on_redefine` | `"error"` | a second definition of a name in the same scope (the first one is attached as a note) |
| `on_unused` | `"ignore"` | a definition that is never used |
| `on_shadow` | `"ignore"` | a definition hiding one in an outer scope |

Each is `"error"`, `"warning"` or `"ignore"`. For names the declarative options can't account for (names provided by the host, implicit globals), `on_unresolved=function` is asked about every use that resolves to nothing: `function(node, ctx)` returns true if the name is fine after all, and may report its own diagnostic through `ctx`.

Languages where assignment defines a variable need no special support: list the assignment target in `define` and set `on_redefine="ignore"`; the first assignment is the definition. `messages={"undefined": "unknown variable '{text}'"}` and `codes={"undefined": "E100"}` override the texts and codes, with the keys `undefined`, `redefined`, `unused`, `shadowed` and `no_member`.

Several `scopes()` rules give separate namespaces; name them with `namespace="function"`.

### Member access

`members=` resolves qualified names such as `Color.red` or `module.function`:

```python
scopes(
    scope=("Program", "Enum"),
    define="Enum > .members",
    define_outer="Enum > .name",     # `Color` names the enum's scope
    use="Name",
    members="Member",                # nodes with a child labelled `target` and one labelled `name`
)
```

A name defined with `define_outer` stands for the scope its node is in, and that scope's own definitions are its members. In `target.name`, `name` is looked up among the members of what `target` resolves to, and nowhere else: `Color.blue` is reported as `'Color' has no member 'blue'` (`on_no_member`, code `no-member`), and `red` alone stays undefined. Chains (`a.b.c`) resolve left to right. When the target is something without members known to the scopes, a variable for instance, the access is left alone. `member_labels=("object", "attr")` changes the two labels.

### Several files: imports

Tell `scopes()` which nodes are import statements, and check the files together:

```python
rules = Rules(parser, [scopes(
    ...,
    members="Member",
    imports=("Import", "FromImport"),        # import statements
    import_all="FromImport:has(> star)",     # those that bring in every name
)])

project = rules.analyze_project({
    "util": "fn helper(x) { return x; }",
    "main": "import util;\nfrom util import helper as h;\nutil.helper; h(1);",
})
project.ok                       # no file has an error
project.diagnostics              # {"util": [...], "main": [...]}
project.file("main")             # that file's Analysis
```

An import statement is read through three labels, `module`, `names` and `alias` (`import_labels=` renames them):

| Statement | Children | Effect |
|---|---|---|
| `import util;` | `module` | defines `util`; `util.helper` looks `helper` up among what the file exports |
| `import util as u;` | `module`, `alias` | the same under the name `u` |
| `from util import a, b;` | `module`, several `names` | defines `a` and `b`, each bound to the definition in `util` |
| `from util import a as x;` | a `names` node holding the name and an `alias` | defines `x` |
| `from util import *;` | `module` (matched by `import_all`) | every exported name is visible; local definitions win |

- **Exports** are a file's top-level definitions; `exports="FuncDef > .name"` narrows them. Imported names are re-exported.
- **Which file a module is:** by default the module's text (quotes removed) is the file's key. `resolve=function` overrides that: `function(module_text, importing_key)` returns a key or `None`, which is where search paths and relative imports go.
- **Diagnostics:** `module 'x' not found` (`on_no_module`, code `no-module`), `module 'util' has no 'x'` (`on_no_export`, code `no-export`), and `'util' has no member 'x'` for a qualified access.
- **Cycles are fine:** every file's exports are collected before any name is resolved.
- **Following an import:** an imported name's `Symbol` has `origin`, the `(file, node index)` of its definition; `project.origin(symbol)` returns that file's `Symbol`, through re-exports. A module's local name has `module`, the key of the file it stands for.

`check()` and `analyze()` see one file and cannot follow imports, so they assume the best: imported names are plain definitions, members of a module are not judged, and a wildcard import silences undefined names in that file. Use `analyze_project()` to have them checked.

### The symbol table

`rules.analyze(source)` returns an `Analysis`:

```python
analysis = rules.analyze(tree)
analysis.diagnostics        # what check() returns
analysis.ok                 # no errors (warnings allowed)
analysis.tree               # the zgram Tree
analysis.symbols            # every Symbol found by scopes() rules
analysis.resolve(node)      # the Symbol a node defines or uses, or None
analysis.at(offset)         # the Symbol defined or used at a byte offset, or None
```

`resolve()` takes a zgram `Node`, a node index, or an AST object built by zgram (it reads `__znode__`), so an interpreter can look variables up by symbol and an editor can implement go-to-definition with `at()`.

A `Symbol` has `name`, `namespace`, `builtin`, `node` and `span` (its definition; `None` for a builtin), `scope` (the index of its scope node; `None` for the global scope), `owns` (the index of the scope it names, if it has members), `uses` / `use_spans`, and in a project `origin` and `module` (see above).

## Types

`types()` type-checks the program. You say which nodes play which part, and what your operators and literals mean; zrules infers the type of every expression and reports what doesn't fit. It types the names a `scopes()` rule resolves, so it needs one in the same `Rules`.

```python
NUMERIC = [("int", "int", "int"), ("float", "float", "float")]

types(
    basic=("int", "float", "str", "bool", "void", "nil"),    # the built-in type names
    coerce={"int": "float"},                                  # an int fits where a float is expected
    literals={"Int": "int", "Float": "float", "String": "str", "Bool": "bool", "Nil": "nil"},
    containers={"ListLit": "list"},                           # [1, 2] is a list[int]
    type_names="TypeName",                                    # a type written in the source
    type_args="GenericType",                                  # list[int]: children `base` and `args`
    optional="OptionalType",                                  # int?: wraps the type inside it
    variables="Let, Param, Field",                            # children `name`, `type`, `value`
    functions="FuncDef",                                      # children `name`, `params`, `returns`
    structs="StructDef",                                      # child `name`; its scope holds the members
    binary="Compare, Sum, Term",                              # children `left`, `op`, `right`
    unary="Neg, Not",                                         # child `operand`
    calls="Call",                                             # children `callee`, `args`
    index="Index",                                            # children `target`, `index`
    assigns="Assign",                                         # children `target`, `value`
    returns="Return",                                         # child `value`
    conditions="If > .cond, While > .cond",                   # must be bool
    operators={
        "+": NUMERIC + [("str", "str", "str")],               # (left, right, result)
        "-": NUMERIC + [("int", "int"), ("float", "float")],  # (operand, result): unary
        "==": [("T", "T", "bool")],                           # T: the same type on both sides
        "not": [("bool", "bool")],
    },
    builtins={"print": "fn(...) -> void", "len": "fn(any) -> int"},
)
```

Every option is optional: leave out `structs` and there are no declared types, leave out `conditions` and conditions aren't checked.

- **Parts are read through labels.** A `variables` node gives its name in the child labelled `name`, its declared type in `type`, its initial value in `value`. If your grammar uses other labels, map them: `labels={"callee": "fn", "value": "init"}`. The roles are `name`, `type`, `value`, `params`, `returns`, `left`, `op`, `right`, `operand`, `callee`, `args`, `target`, `index`, `base` and `items`. A call's callee is its `callee` child, else `name`, else `target` (what zgram's `@postfix` folding produces); a unary operator without an `op` child is the text before its operand.
- **Inference.** A variable without a declared type has the type of its value; a call has the function's result type; an operator's result comes from its table. Anything a wrapper node contains alone (parentheses, a pass-through rule) has the type of what it contains.
- **Unknown is compatible with everything.** A parameter without a type, a function without a declared result, an operator not in the table: their type is unknown, and unknown is never an error. A program with no type annotations has no type errors, and you can add types gradually. `unknown` and `any` can be written wherever a type is, to say so explicitly.
- **Types** are written `int`, `list[int]`, `map[str, int]`, `int?`, `fn(int, str) -> bool`, `fn(str, ...) -> void` (any number of further arguments). Generic types are told apart by name and arguments; a one-argument generic is indexed by `int` and gives its argument, a two-argument one is indexed by its first and gives its second, and indexing a `str` gives a `str`.
- **Optional.** `T?` takes a `T`, `nil`, or another optional that fits. Members are looked up through it.
- **Declared types.** A `structs` node declares a type named by its `name` child. The variables declared directly in its scope are its fields, the functions its methods: `p.x` and `p.scale(2)` are typed through them. Calling the type constructs it, one argument per field, in order. For type names to refer to declared types, the `scopes()` rule must resolve them: include the type-name node in its `use`. The names in `basic` are made builtins of that rule automatically.
- **The types the checker itself relies on** (a condition is `bool`, a list index is `int`, `return;` returns `void`, `nil` fits an optional, indexing a `str`) can be renamed: `names={"bool": "Boolean", "nil": "Null"}`.

| Code | Key | |
|------|-----|---|
| `type-mismatch` | `mismatch` | a value of the wrong type in a declaration, an assignment, a list, an index |
| `bad-operand` | `operator` | an operator applied to types its table doesn't list |
| `arity` | `arity` | a call with the wrong number of arguments |
| `bad-argument` | `argument` | an argument of the wrong type |
| `not-callable` | `not_callable` | a call of something that is not a function or a type |
| `no-field` | `no_field` | a member the type doesn't have |
| `bad-return` | `bad_return` | a returned value that isn't the function's declared result |
| `bad-condition` | `condition` | a condition that isn't `bool` |
| `unknown-type` | `unknown_type` | a type name that names no type (when the name isn't already reported as undefined) |
| `not-indexable` | `not_indexable` | indexing something that can't be |

`codes={"mismatch": "T001"}` changes a code, `ignore=("condition",)` turns a check off, `severity="warning"` downgrades them all, and `namespace=` picks the `scopes()` rule when there are several.

```python
analysis = rules.analyze(source)
analysis.type_of(node)      # 'list[int]', or None if unknown
analysis.symbols[0].type    # 'fn(int, int) -> int'
```

Custom rules get the same through `ctx.type_of(node)`. With `analyze_project()`, types follow imports: an imported function, variable or struct has the type its own file gives it, and a struct imported through two paths is one type.

The checker has no recursion limit to run into: a chain of thousands of definitions each depending on the next, within a file or across files, is typed without deep recursion.

## Control flow

`flow()` follows the paths a program can take. It reports code that can't be reached, functions that may end without returning, and variables used before they have a value.

```python
flow(
    sequences="Program, Block",            # nodes whose children run one after the other
    functions="FuncDef",                   # a flow of its own, not run where it is written
    branches="If",                         # runs one of its arms
    otherwise="If > .else",                # the arm that runs when no other does
    loops="While",                         # the body may run any number of times
    forever="Loop",                        # ends only through a break
    at_least_once="DoWhile",               # the body runs before the condition
    exits="Return, Throw",                 # nothing runs after these
    breaks="Break",
    continues="Continue",
    must_return="FuncDef:has(> .returns)", # functions whose end must not be reachable
    variables="Let",                       # declarations: children `name`, `value`
    assigns="Assign",                      # assignments: child `target`
)
```

Only `sequences` is required; every other option adds to what is understood.

- **Unreachable code** (`unreachable`, a warning by default): the first statement of a sequence that no path gets to, after a `return` or `break`, after a branch whose arms all leave, after a loop that never ends. It is reported once per sequence. A function written after a `return` is not dead code: it is a definition.
- **Missing return** (`missing-return`): a `must_return` function whose end some path reaches. It is reported on the function's `name` child.
- **Used before it has a value** (`unassigned`): a variable that is declared without a value (a `variables` node with no `value` child), or defined by an assignment (the `target` of an `assigns` node is its definition, as in languages without declarations), is followed from the start of its function. A use on a path where it has no value yet is an error, worded "is used" when no path gives it one and "may be used" when only some do. A variable is reported once. A declaration or an assignment may have several `name` / `target` children (`local a, b`, `a, b = 1, 2`). This part reads the names a `scopes()` rule resolved (`namespace=` says which, when there are several).
- **Branches.** The arms of a branch are its child sequences, or what `arms=` selects; everything else in it (the condition) always runs. A branch covers every case only if one of its arms is an `otherwise` arm, or a nested branch (`else if`). Without one, the path that takes no arm counts too.
- **Loops.** The body of a loop is its first child sequence; what comes before it (the condition) runs at least once, what comes after it (the step of a `for`, the condition of a `do ... while`) after each iteration. What a loop body gives a value to may not have one after the loop, unless the loop is `at_least_once`.
- **Functions** are separate: a use inside a nested function of a variable of the enclosing one is not judged (when the nested function runs is not known), and a variable that another function assigns is not followed at all.
- **`exits`** can be any node, not just a statement: `exits="Return, Call[callee=exit]"` makes a call of `exit()` end the path.

`labels={"target": "lhs"}` renames the children read (`name`, `value`, `target`); `on_unreachable`, `on_missing_return` and `on_unassigned` are `"error"`, `"warning"` or `"ignore"`; `messages=` and `codes=` take the keys `unreachable`, `missing_return`, `unassigned` and `maybe_unassigned`. Control structures nested more than 256 deep are not looked into.

## Custom rules

Anything the declarative rules don't cover is a Python function, called for every node matching a selector:

```python
rules = Rules(parser, [scopes(...)])

@rules.rule("Call", code="arity")
def check_arity(call, ctx):
    symbol = ctx.resolve(call.get("name"))
    if symbol is None or symbol.builtin:
        return
    func = ctx.tree.node(symbol.node).parent()
    expected, got = len(func.get_all("params")), len(call.get_all("args"))
    if expected != got:
        ctx.error(call, f"{symbol.name}() takes {expected} arguments, got {got}")
```

The function receives the zgram `Node` and a context:

| | |
|---|---|
| `ctx.error(node, message, code=None)` | report an error; also `ctx.warning` and `ctx.note` |
| `ctx.resolve(node)` | the `Symbol` a node defines or uses, or `None` |
| `ctx.type_of(node)` | the type `types()` found for a node, as text, or `None` |
| `ctx.tree`, `ctx.symbols` | the tree being checked and its symbols |

`node` is a `Node`, a node index, an AST object, or a `(start, end)` span. Custom rules run after the declarative rules and `scopes()`, so the symbols are complete. `rules.add(selector, function)` and `custom(selector, function)` in the rule list do the same as the decorator. An exception raised by the function propagates out of `check()`.

## Checking

```python
rules.check(tree)        # a zgram Tree (parser.parse_tree(text))
rules.check(node)        # a zgram Node (its whole tree is checked)
rules.check(source)      # str or bytes: parsed first; raises zgram.ParseError
rules.analyze(...)       # the same, returning an Analysis
```

`check()` returns a list of `zgram.Diagnostic` in source order. The tree must come from the grammar the rules were compiled against.

zrules reads the tree in place through zgram's `zgram.tree.v1` capsule; no Python object is created per node (custom rules get a `Node` for each node they are called on). `zrules.TREE_ABI` is the tree layout version it understands.

### Performance

Each rule visits only the nodes its selector can end on, found through an index by grammar rule and by label. On a 136 KB source (44,000 nodes), where zgram's parse takes about 0.3 ms:

| | Time |
|---|---|
| 4 structural rules | 0.4 ms |
| 19 structural rules | 0.9 ms |
| `scopes()` resolving 8,000 definitions and 16,000 uses (34,000 nodes) | 1.3 ms |
| `scopes()` + `types()` on a typed program: 896 KB, 260,000 nodes, 20,000 typed declarations with calls | 31 ms |
| the same kind of program with `flow()` added (773 KB, 265,000 nodes) | 39 ms, 4.5 ms of it flow |
| `analyze_project()` on 8,000 small files importing one another, with types | 80 ms |

`Symbol` objects are created only when asked for (`symbols`, `resolve()`, `at()`), so `check()` pays nothing for them.

## Example: a whole language

[examples/tiny](examples/tiny) is a small language with functions, loops and variables. zgram parses it, the rules above find every static error in one pass (`break` outside a loop, undefined names, duplicate definitions, wrong argument counts, calling a variable), and the interpreter then looks variables up through the symbols zrules resolved instead of searching scopes itself.

```
$ python examples/tiny/tiny.py bad.tiny
bad.tiny:2:9: error: add() takes 2 arguments, got 1 [arity]
    2 | let x = add(1);
      |         ^^^^^^
bad.tiny:3:1: error: 'break' outside loop [break-outside-loop]
    3 | break;
      | ^^^^^^
```

## Example: a typed language

[examples/typed](examples/typed) is a statically typed language with structs, methods, optionals, lists and imports between files. Its whole front end after parsing is about a hundred lines of rule options: structure, names, types and flow.

```
$ python examples/typed/typedlang.py geometry.ty mistakes.ty
mistakes.ty:1:42: error: module 'geometry' has no 'area' [no-export]
mistakes.ty:3:4: error: 'describe' may end without returning a value [missing-return]
mistakes.ty:14:12: error: 'result' may be used before it has a value [unassigned]
mistakes.ty:15:5: warning: unreachable code [unreachable]
mistakes.ty:19:31: error: argument 1 of start.plus(): expected 'Point', got 'int' [bad-argument]
mistakes.ty:20:38: error: 'Point' has no field 'z' [no-field]
mistakes.ty:21:17: error: operator '+' cannot be applied to 'str' and 'int' [bad-operand]
...
```

## Example: a real language

[examples/lua](examples/lua) checks Lua 5.4: a complete grammar in zgram, and in zrules the errors `luac` reports beyond syntax (`break` outside a loop, `...` outside a vararg function, assignment to a `<const>` variable, `goto` without a visible label, duplicate labels) plus a linter's warnings (unused and shadowed locals, locals read before they are given a value, unreachable code).

The test suite runs it over the Lua code shipped with nmap and sysdig when they are installed: 830 files and 7 MB of code in production use. Every file parses, nothing in them is reported as an error, and the warnings that were checked by hand are real (code after an `if` whose branches all return, locals that are never read).

## Building from source

Requires [Zig](https://ziglang.org/) 0.16.

```bash
pip install pyoz
pyoz build --release     # builds the wheel into dist/
pip install dist/*.whl
python -m pytest test
```

`pip install .` does the same through the PyOZ build backend, and `zig build` alone produces `zig-out/lib/zrules.so` for quick iteration.

## License

MIT
