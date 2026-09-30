# zrules reference

Every function, option, class and diagnostic code. The [README](../README.md) explains how they fit together; this page is for looking things up.

- [Selectors](#selectors)
- [Rules()](#rules)
- [Structural rules](#structural-rules): `inside`, `unique`, `forbid`, `require`, `count`
- [scopes()](#scopes)
- [types()](#types)
- [flow()](#flow)
- [custom()](#custom)
- [Analysis, Symbol, Project, Context](#results)
- [Diagnostic codes](#diagnostic-codes)
- [Limits](#limits)

Wherever an option takes a selector, it takes a selector text, a comma-separated list in one text, or a sequence of texts. An option left out (or `None`) is not applied.

## Selectors

| Form | Matches |
|---|---|
| `name` | nodes of the grammar rule `name`, or of every rule mapped to the class `name` (`-> Name`) |
| `*` | any node |
| `.label` | a node labelled `label` in its parent |
| `name.label` | both |
| `[label=text]` | a node with a direct child labelled `label` whose text is exactly `text` |
| `a > b` | a `b` that is a direct child of an `a` |
| `a b` | a `b` anywhere inside an `a` |
| `a + b` | a `b` whose previous sibling is an `a` |
| `a ~ b` | a `b` with an `a` among its previous siblings |
| `:not(x)` | a node that does not match the single part `x` |
| `:has(x)` | a node with a descendant matching `x`; `:has(> x)`: a direct child |
| `:nth(n)`, `:first`, `:last` | the n-th (from 1), first or last among the siblings that match the rest of the part |
| `a, b` | either |

A selector has at most 16 parts. Names and labels that the grammar doesn't have are a `ValueError` when the rules are compiled. `@silent` rules produce no nodes and can't be selected.

## Rules()

```python
Rules(parser, rules=None)
```

`parser` is a compiled zgram parser; `rules` a sequence of what the functions below return. Compiling validates every selector, label and option against the grammar.

| Member | |
|---|---|
| `check(source, recover=False)` | the diagnostics, as a list of `zgram.Diagnostic` in source order |
| `analyze(source, recover=False)` | the same check, returning an `Analysis` |
| `analyze_project(files, resolve=None, recover=False)` | check several files together; `files` is a dict of key -> source; returns a `Project` |
| `add(selector, function, code=None)` | add a custom rule |
| `rule(selector, code=None)` | the same as a decorator |
| `len(rules)` | the number of rules |

`source` is a zgram `Tree`, a zgram `Node` (its whole tree is checked), or `str` / `bytes` (parsed first; raises `zgram.ParseError`, or with `recover=True` is parsed with zgram's error recovery). A tree from another grammar is a `ValueError`.

A tree parsed with recovery (`parser.parse_tree(text, recover=True)`, zgram 0.3+) is checked like any other, with three differences:

- Its syntax errors (`tree.errors`, code `syntax`) are in the diagnostics, in source order among the findings.
- Nothing is reported about the broken text: a finding whose span overlaps an error node or contains a syntax error is left out (whatever rule made it, custom ones included).
- Nothing is reported *because of* it: `flow()` skips a function (or the top level) whose own body has broken text, since its paths can't be followed (a `return` that didn't parse would be a missing return); an undefined, unused or missing-member name that occurs in the broken text isn't reported (it was probably defined or used there); and `no-export` isn't reported for a name that occurs in the broken text of the file imported from.

`resolve(module_text, importing_key)` returns the key of the file a module name stands for, or `None`. Without it, the module's text (quotes removed) is the key.

## Structural rules

All take `message=`, `code=` (default: the rule's name) and `severity=` (`"error"`, `"warning"`, `"note"`; default `"error"`).

| Rule | Reports | Default message |
|---|---|---|
| `inside(selector, within, stop_at=None)` | a match without an ancestor matching `within`, looking no further up than an ancestor matching `stop_at` | `{rule} is not allowed here` |
| `unique(selector, within=None)` | a match whose text was already seen in its group (note: the first one) | `duplicate '{text}'` |
| `forbid(selector)` | every match | `{rule} is not allowed here` |
| `require(selector)` | a node matching all but the last part, without a match of the whole (needs two parts or more) | `{rule} is incomplete` |
| `count(selector, exactly=None, min=None, max=None, within=None)` | a group whose number of matches is out of range | `wrong number of items ({count})` |

A group (`unique`, `count`) is the nearest ancestor matching `within`; without `within`, the node the selector's first part matched, or the whole tree for a one-part selector.

Message placeholders: `{text}`, `{rule}`, `{field}`, `{parent}`, `{count}`, `{min}`, `{max}`, and `{owner}` in the messages of `scopes()`.

## scopes()

| Option | Default | |
|---|---|---|
| `scope` | required | nodes that open a scope |
| `define` | required | nodes whose text is a name defined in the scope around them |
| `use` | required | nodes whose text must resolve to a definition |
| `define_outer` | | definitions made in the scope outside the one their node is in; the name stands for that inner scope (its members) |
| `hoist` | | definitions visible before their position |
| `after` | | definitions visible only once their parent node has ended |
| `outside` | | nodes whose names are looked up from the scope outside the one they are written in |
| `builtins` | `()` | names that are always defined |
| `ordered` | `True` | within a scope, a definition is visible only from its position on |
| `namespace` | `"name"` | the name of this set of names; several `scopes()` rules are independent |
| `members` | | member accesses, read through `member_labels` |
| `member_labels` | `("target", "name")` | |
| `imports` | | import statements, read through `import_labels` |
| `import_all` | | import statements that bring in every exported name |
| `import_labels` | `("module", "names", "alias")` | |
| `exports` | every top-level definition | definitions other files can import |
| `on_undefined` | `"error"` | |
| `on_redefine` | `"error"` | |
| `on_unused` | `"ignore"` | |
| `on_shadow` | `"ignore"` | |
| `on_no_member` | `"error"` | |
| `on_no_module` | `"error"` | |
| `on_no_export` | `"error"` | |
| `on_unresolved` | | `function(node, ctx)` asked about each use that resolves to nothing; a true result accepts the name |
| `messages`, `codes` | | dicts overriding texts and codes, keyed `undefined`, `redefined`, `unused`, `shadowed`, `no_member`, `no_module`, `no_export` |

Levels are `"error"`, `"warning"` or `"ignore"`.

## types()

Needs a `scopes()` rule in the same `Rules`. Its `basic` names become builtins of that rule.

| Option | |
|---|---|
| `basic` | names of the built-in types |
| `names` | what the language calls `bool`, `int`, `str`, `void` and `nil`, the types the checker itself relies on: `{"bool": "Boolean"}` |
| `coerce` | implicit conversions: `{"int": "float"}` |
| `literals` | selector -> type: `{"Int": "int"}` |
| `containers` | selector -> generic name, for literals whose `items` give the argument: `{"ListLit": "list"}` |
| `type_names` | nodes whose text names a type |
| `type_args` | generic types: children `base`, `args` |
| `optional` | nodes that make the type inside them optional |
| `variables` | declarations: children `name`, `type`, `value` |
| `functions` | children `name`, `params` (each a `variables` node or a bare name), `returns` |
| `structs` | declared types: child `name`; the variables and functions in their scope are fields and methods |
| `binary` | children `left`, `op`, `right` |
| `unary` | child `operand`; the operator is the `op` child, else the text before the operand |
| `calls` | the callee is the child `callee`, else `name`, else `target`; arguments are the `args` children |
| `index` | children `target`, `index` |
| `assigns` | child `target` (else `name`), child `value` |
| `returns` | child `value`; checked against the `returns` of the nearest `functions` ancestor |
| `conditions` | expressions that must be `bool` |
| `operators` | operator text -> rows `(left, right, result)` or `(operand, result)`; `T` stands for one type throughout a row, `any` for anything |
| `builtins` | name -> type text, for names in the `scopes()` rule's `builtins` |
| `labels` | role -> label, to rename the children read: `name`, `type`, `value`, `params`, `returns`, `left`, `op`, `right`, `operand`, `callee`, `args`, `target`, `index`, `base`, `items` |
| `namespace` | the `scopes()` rule to type (default: the first) |
| `severity` | `"error"` (default), `"warning"` or `"note"`, for every type diagnostic |
| `codes` | kind -> code |
| `ignore` | kinds not to report |

Kinds: `mismatch`, `operator`, `arity`, `argument`, `not_callable`, `no_field`, `bad_return`, `condition`, `unknown_type`, `not_indexable`.

Type texts: `int`, `list[int]`, `map[str, int]`, `int?`, `fn(int, str) -> bool`, `fn(str, ...) -> void`, `fn(int)` (returns `void`), `unknown` / `any` (not checked). They nest at most 64 deep.

Rules of compatibility: a type fits itself; `unknown` fits and is fitted by everything; `coerce` pairs fit one way, and chain (`int` -> `float` -> `number`); `T?` takes `T`, `nil` and optionals that fit; two generic types fit when their names are equal and each argument is the same or unknown on one side (`list[int]` does not fit `list[float]`, an empty list fits any list); a function type fits another with the same parameters (or unknown ones) and a result that fits.

## flow()

| Option | Default | |
|---|---|---|
| `sequences` | required | nodes whose children run one after the other |
| `functions` | | nodes with a flow of their own |
| `branches` | | nodes that run one of their arms |
| `arms` | a branch's child sequences | the arms; a branch that is a child of a branch is always an arm |
| `otherwise` | | arms that make their branch cover every case |
| `loops` | | the body (first child sequence) may run any number of times |
| `forever` | | loops that end only through a `break` |
| `at_least_once` | | loops whose body runs before the condition |
| `exits` | | nodes after which nothing runs |
| `breaks`, `continues` | | |
| `must_return` | | functions whose end must not be reachable |
| `variables` | | declarations: children `name` (one or more), `value`; without a `value` the names are followed |
| `assigns` | | assignments: children `target` (one or more), else `name` |
| `labels` | | role -> label for `name`, `value`, `target` |
| `namespace` | the first `scopes()` rule | whose names are followed |
| `on_unreachable` | `"warning"` | |
| `on_missing_return` | `"error"` | |
| `on_unassigned` | `"error"` | |
| `messages`, `codes` | | keyed `unreachable`, `missing_return`, `unassigned`, `maybe_unassigned` |

`variables` and `assigns` need a `scopes()` rule. A variable is followed if it is declared without a value or defined by an assignment, within the function that declares it, and only if no other function assigns it.

## custom()

```python
custom(selector, function, code=None)     # in the rule list
rules.add(selector, function, code=None)
@rules.rule(selector, code=None)
```

`function(node, ctx)` is called for every match, after every other rule has run. Exceptions propagate out of `check()`.

## Results

### Analysis

| Member | |
|---|---|
| `diagnostics` | list of `zgram.Diagnostic`, in source order |
| `ok` | no diagnostic is an error |
| `tree` | the zgram `Tree` |
| `symbols` | every `Symbol`, builtins included |
| `resolve(node)` | the `Symbol` a node defines or uses, or `None` |
| `at(offset)` | the `Symbol` defined or used at a byte offset, or `None` |
| `type_of(node)` | the type of a node as text, or `None` when unknown or without a `types()` rule |

`node` is a zgram `Node`, a node index, or an AST object built by zgram. An `Analysis` stays valid after its `Rules` and `Project` are gone.

### Symbol

| Member | |
|---|---|
| `name`, `namespace` | |
| `builtin` | defined by the rules, not by the source |
| `node`, `span` | the defining node's index and `(start, end)` (for an imported name, where it is imported); `None` for a builtin |
| `scope` | the index of the scope node it is defined in; `None` for the global scope |
| `owns` | the index of the scope it names (its members), or `None` |
| `uses`, `use_spans` | the nodes that use it, in source order |
| `type` | its type as text, or `None` |
| `origin` | in a project, for an imported name: `(file key, node index)` of its definition |
| `module` | in a project, for a module's local name: the key of the file it stands for |

### Project

| Member | |
|---|---|
| `file(key)` | that file's `Analysis` |
| `files` | the keys |
| `diagnostics` | dict of key -> diagnostics |
| `ok` | no file has an error |
| `origin(symbol)` | the `Symbol` an imported name comes from, through re-exports |
| `len(project)` | the number of files |

### Context

What a custom rule's function (and `on_unresolved`) receives as `ctx`.

| Member | |
|---|---|
| `error(node, message, code=None)`, `warning(...)`, `note(...)` | report; `node` may also be a `(start, end)` span |
| `resolve(node)` | as `Analysis.resolve` |
| `type_of(node)` | as `Analysis.type_of` |
| `tree`, `symbols` | |

## Diagnostic codes

| Code | From | Default level |
|---|---|---|
| `inside`, `unique`, `forbid`, `require`, `count` | the structural rules (or their `code=`) | error |
| `undefined-name` | `scopes()` | error |
| `redefined-name` | `scopes()` | error |
| `unused-name` | `scopes()` | ignored |
| `shadowed-name` | `scopes()` | ignored |
| `no-member` | `scopes(members=)` | error |
| `no-module`, `no-export` | `scopes(imports=)` in a project | error |
| `type-mismatch`, `bad-operand`, `arity`, `bad-argument`, `not-callable`, `no-field`, `bad-return`, `bad-condition`, `unknown-type`, `not-indexable` | `types()` | error |
| `unreachable` | `flow()` | warning |
| `missing-return` | `flow(must_return=)` | error |
| `unassigned` | `flow(variables=, assigns=)` | error |

## Limits

- A selector has at most 16 parts.
- A grammar has at most 4096 rules and 255 labels (zgram's limits).
- `flow()` does not look into control structures nested more than 256 deep.
- Type texts in options nest at most 64 deep. Types in the source have no such limit, and neither have chains of definitions that depend on one another.
- Every check is a whole-file check: there is no incremental mode. With names, types and flow it costs about 0.06 ms per thousand nodes, so a file is checked again on every change, and a project of thousands of files in well under a second.
- `zrules.TREE_ABI` is the version of zgram's tree layout this build reads; a tree with another version is refused with a `RuntimeError`.
