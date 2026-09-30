"""Shared fixtures: a small language with labels, classes and folded expressions."""

import pytest
import zgram

GRAMMAR = r"""
program     = ws (body:stmt ws)*                                      -> Program
@silent stmt = import_stmt | from_stmt | funcdef | enum_def | while_stmt | return_stmt | break_stmt | let_stmt | expr_stmt
import_stmt = 'import' kw ws module:ident (ws 'as' kw ws alias:ident)? ws ';'   -> Import
from_stmt   = 'from' kw ws module:ident ws 'import' kw ws (star | names:import_name (ws ',' ws names:import_name)*) ws ';'  -> FromImport
import_name = ident (ws 'as' kw ws alias:ident)?
star        = '*'
enum_def    ='enum' kw ws name:ident ws '{' ws (members:ident ws)* (stmt ws)* '}'   -> Enum
funcdef     = 'fn' kw ws name:ident ws '(' ws (params:ident (ws ',' ws params:ident)*)? ws ')' ws body:block  -> FuncDef
block       = '{' ws (stmt ws)* '}'                                   -> list
while_stmt  = 'while' kw ws cond:expr ws body:block                   -> While
return_stmt = 'return' kw (ws value:expr)? ws ';'                     -> Return
break_stmt  = 'break' kw ws ';'                                       -> Break()
let_stmt    = 'let' kw ws name:ident ws '=' ws value:expr ws ';'      -> Let
@silent expr_stmt = expr ws ';'
@left expr  = left:operand (ws op:addop ws right:operand)*            -> BinOp
@postfix operand = target:atom (member)*
member      = '.' name:ident                                          -> Member
@silent atom = number | call | ident
call        = name:ident ws '(' ws (args:expr (ws ',' ws args:expr)*)? ws ')'  -> Call
number      = [0-9]+                                                  -> int
ident       = !keyword [a-z_]+                                        -> Name
addop       = [+\-]                                                   -> str
@silent keyword = ('fn' | 'enum' | 'while' | 'return' | 'break' | 'let' | 'import' | 'from' | 'as') kw
@silent kw  = ![a-z_]
@silent ws  = [ \t\n]*
"""


@pytest.fixture(scope="session")
def parser():
    return zgram.compile(GRAMMAR)


def found(rules, source):
    """[(code, line, column, flagged text)] for a source text."""
    data = source.encode()
    return [(d.code, d.line, d.column, data[d.span[0] : d.span[1]].decode()) for d in rules.check(source)]
