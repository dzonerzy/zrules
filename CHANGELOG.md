# Changelog

All notable changes to zrules are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- **`rules.analyze()`** returns an `Analysis` with the diagnostics and the symbol table: `symbols`, `resolve(node)`, `at(offset)`.
- **Custom rules:** `@rules.rule(selector)`, `rules.add()` and `custom()` call a Python function with the node and a context (`error`, `warning`, `note`, `resolve`).
- **`examples/tiny`:** a small language whose static errors are all found by zrules.
- **`Rules(parser, rules)`** compiles rules against a grammar; `rules.check(tree)` checks a zgram `Tree` or `Node` (or source text) natively through the `zgram.tree.v1` capsule and returns `zgram.Diagnostic`s in source order.
