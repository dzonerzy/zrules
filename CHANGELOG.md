# Changelog

All notable changes to zrules are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Generic functions and types** (`types()`, children `tparams` of `functions` and `structs`): `fn first[T](xs: list[T]) -> T`, `struct Box[T] { value: T; }`. A call works out the type parameters from its arguments, part by part, and types its result with them (`first([1])` is an `int`); a parameter it can't tell is `unknown`. `Box[int]` (a `type_args` whose base names the struct) is an instance; calling `Box` makes the one its arguments say; an instance's fields and methods have its arguments. Inside, a type parameter is a type of its own.
- **Union types** (`types(unions=...)`, children `members`; `int | str` in type texts): a value fits a union if it fits a member, a union where every member does; operators and fields apply to unions member by member.
- **Subtyping between declared types** (children `bases` of `structs`: `struct Circle : Shape`): a type fits its bases (through any chain), has their fields (first, when calling the type) and methods. Function types fit with parameters the other way round (a function taking a `float` goes where one taking an `int` is wanted).
- examples/typed: type parameters, unions (a type written `A | B`, and in parentheses), bases.
- **`flow(gotos=..., targets=...)`**: control flow that knows jumps to labels (Lua's `goto`). Code after a jump is unreachable up to a label a reachable jump goes to; variables follow the jumps, back ones too (the function walked again while a jump back brings something new). A jump goes to the nearest label of its name among the statements of its sequence or of one around it, in its function; one with no label is reported (`no_label`, `on_no_label=`). The label's name is the child `label` (the child `name` unless `labels=` says another). examples/lua uses them.

## [0.1.7] - 2026-10-07

### Changed
- Built with PyOZ 0.13.10: on Windows, Python's data (None, the exceptions, the types) read at run time, never a constant holding an import slot's address (the Windows wheel of 0.1.6 had none, now one can't be built).

## [0.1.6] - 2026-10-07

### Added
- **`rules.analyze(source, builtins=[...])`**: names the environment defines, for this analysis only, besides the rules' own builtins (those of the first `scopes()` rule). A REPL checks each entry with the names its earlier entries defined; a program defining one of them again has its own symbol.

## [0.1.5] - 2026-10-01

### Changed
- **`Analysis.capsule`** is now `"zrules.analysis.v2"` (ABI 2): it also lists the keys of the modules each file imports, found in the project or not. A tool checking part of a project (an editor re-checking the files an edit can affect) learns which other files to bring in.

## [0.1.4] - 2026-10-01

### Added
- **`Analysis.capsule`** (`"zrules.analysis.v1"`) and **`Selector.capsule`** (`"zrules.selector.v1"`): the symbol table and a selector's match function for native code in other packages, without a Python object per symbol, use or node (`src/native_abi.zig` is the layout). zlsp reads its results this way.

### Fixed
- **An imported name used as a type** was an `unknown type` when its definition couldn't be seen: in a file checked on its own (which assumes imported names are fine), or when the module is missing (already reported as `no-module`). A name whose type isn't known is no longer judged as a type; a name known not to be one still is.
- **Basic type names** (`int`, `float`, ...) had no type as symbols; they are now `type[int]`, like a struct's name is `type[Point]`.

### Performance
- `Selector.match()` rejects a node by the rule and label its selector's last part names before matching the whole selector.

## [0.1.3] - 2026-10-01

### Added
- **`Selector(parser, text)`**: a selector on its own, compiled against a parser's grammar; `match(tree)` gives the indices of the matching nodes, in source order. For tools that classify nodes the way rules do (an editor's outline and highlighting).
- **`Analysis.visible(offset, namespace=None)`**: the symbols a name written at a position could refer to, by the `scopes()` rule's own rules (ordering, hoisting, builtins, imports), innermost first and inner names hiding outer ones. For completion.

## [0.1.2] - 2026-10-01

### Added
- **Broken code:** `check()`, `analyze()` and `analyze_project()` take `recover=True` to parse text with zgram's error recovery, and accept trees parsed that way (`parser.parse_tree(text, recover=True)`). The tree's syntax errors are in the diagnostics, in source order among the findings, and nothing is reported about the broken text or because of it: no finding touching an error node or a syntax error, no flow findings in a function (or the top level) whose own body has broken text, no undefined, unused or missing-member name that occurs in the broken text, and no missing export for a name in the broken text of the file imported from.

### Fixed
- **A list literal with an item of unknown type** was typed from its other items: `[x, 1]` with `x` unknown became `list[int]`, and then a mistake wherever a `list[float]` was expected. It is now a list of unknown, which fits anywhere; the known items are still checked against each other.

### Changed
- Requires zgram-py 0.3.1 or later.

## [0.1.1] - 2026-09-30

### Changed
- **Package description:** the project's logo, and a README laid out like zgram's (performance and examples first, then installation, the guide, API reference, architecture, threads and known issues), with links that work on PyPI. The code is the same as 0.1.0.

## [0.1.0] - 2026-09-30

### Added
- **Selectors** over zgram parse trees: rule and class names, `*`, `.label`, `name.label`, `[label=text]`, child (`>`) and descendant combinators.
- **Rules:** `inside`, `unique`, `forbid`, `require` and `count`, each with `message`, `code` and `severity`.
- **Selector pseudo-classes:** `:not(...)`, `:has(...)`, `:nth(n)`, `:first`, `:last`.
- **Sibling selectors** `a + b` and `a ~ b`, and **selector lists** (`a, b` or a sequence) wherever a selector is accepted.
- **`within=`** for `unique` and `count`: group by the nearest matching ancestor.
- **Message placeholders** `{field}`, `{parent}`, `{min}` and `{max}`.
- **`on_unresolved=`** for `scopes()`: a function that decides about names that resolve to nothing.
- **`scopes()`:** name resolution with nested scopes, outer definitions, hoisting, builtins, separate namespaces, and diagnostics for undefined, redefined, unused and shadowed names.
- **Member access:** `scopes(members=...)` resolves `target.name` in the scope the target names (enums, modules, static members) and reports missing members.
- **Several files:** `scopes(imports=..., import_all=...)` and `rules.analyze_project(files, resolve=None)` resolve imports between files (module imports with qualified access, named imports with aliases, wildcard imports, re-exports, cycles) and report missing modules and names. `Project` gives each file's `Analysis` and follows a name to its definition with `origin()`.
- **Types:** `types()` infers and checks types: declared and inferred variables, functions and calls (arity, argument types, variadic builtins), operators through a table, optionals (`T?` and `nil`), generic types (`list[int]`, `map[str, int]`), indexing, declared types with fields, methods and constructors, return types and conditions. Unknown types are compatible with everything, so untyped programs pass and types can be added gradually. Types follow imports in `analyze_project()`. `Analysis.type_of(node)`, `Symbol.type` and `ctx.type_of(node)` expose the result. Long dependency chains are typed without deep recursion.
- **Control flow:** `flow()` follows sequences, branches, loops, `break` / `continue` and exits, and reports unreachable code, functions that may end without returning, and variables used before they have a value on every path.
- **`scopes(outside=...)`:** parts of a scope node evaluated before the scope exists (the bounds of a `for`, a default value) look names up from the scope outside.
- **`examples/typed`:** a typed language with structs, optionals and imports, checked by structure, names, types and flow together.
- **`examples/lua`:** a complete Lua 5.4 grammar and checker, tested on the Lua code shipped with nmap and sysdig.
- **[Reference](docs/reference.md)** of every option, class member and diagnostic code.
- **Parallel projects:** `analyze_project()` checks the files on several threads, with the Python lock released: about twice as fast as checking them one after another on large projects.
- **Speed:** a program of 265,000 nodes is checked with names, types and flow in about 15 ms, where zgram parses it in 4.6 ms.
- **`rules.analyze()`** returns an `Analysis` with the diagnostics and the symbol table: `symbols`, `resolve(node)`, `at(offset)`.
- **Custom rules:** `@rules.rule(selector)`, `rules.add()` and `custom()` call a Python function with the node and a context (`error`, `warning`, `note`, `resolve`).
- **`examples/tiny`:** a small language whose static errors are all found by zrules.
- **`Rules(parser, rules)`** compiles rules against a grammar; `rules.check(tree)` checks a zgram `Tree` or `Node` (or source text) natively through the `zgram.tree.v1` capsule and returns `zgram.Diagnostic`s in source order.
