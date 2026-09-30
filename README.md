# zrules

**Static rules over [zgram](https://github.com/dzonerzy/zgram) parse trees.**

zgram tells you whether a text is well-formed. zrules tells you whether it is *valid*: `break` only inside a loop, no duplicate parameters, `len()` takes one argument. You write each check as one line; zrules runs them natively over zgram's parse tree and reports every violation as a `zgram.Diagnostic`.

It covers three levels of checking: one-line structural rules, name resolution with scopes (which also gives you a symbol table), and custom rules written as Python functions. Part of zsuite (zgram, zrules, zrun, zlsp).

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
