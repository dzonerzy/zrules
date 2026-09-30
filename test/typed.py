"""The typed language of examples/typed, with helpers for the types() and flow() tests."""

import os
import sys

from zrules import Rules, scopes, types

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples", "typed"))
from typedlang import FLOW, GRAMMAR, PARSER, SCOPES, TYPES  # noqa: E402, F401


def make(scope_options=None, **type_options):
    """Rules for the language, with some types() options replaced."""
    options = dict(TYPES)
    options.update(type_options)
    scope = dict(SCOPES)
    scope.update(scope_options or {})
    return Rules(PARSER, [scopes(**scope), types(**options)])


RULES = make()


def problems(source, rules=RULES):
    """[(code, message, line, column)] for a source text."""
    return [(d.code, d.message, d.line, d.column) for d in rules.check(source)]


def messages(source, rules=RULES):
    return [d.message for d in rules.check(source)]
