# Changelog

All notable changes to zrules are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
