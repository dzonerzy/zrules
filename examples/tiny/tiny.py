"""tiny: a small language, checked by zrules before it runs.

zgram parses it and builds the AST; zrules checks the program and resolves
every name; the interpreter then only executes. Compare with zgram's own
examples/tiny, where the interpreter has to find these errors itself, one at
a time, and only on the lines that run:

    'break' outside a loop, 'return' outside a function, undefined names and
    functions, names defined twice, calls with the wrong number of arguments,
    calling something that is not a function

Here they are all reported up front, together, and the interpreter looks
variables up through the symbols zrules resolved.

    python tiny.py program.tiny
"""

import sys
from dataclasses import dataclass

import zgram
from zrules import Rules, forbid, inside, scopes

GRAMMAR = r"""
program     = ws (body:stmt ws)*                                      -> Program
@silent stmt = funcdef | while_stmt | if_stmt | return_stmt | break_stmt
             | let_stmt | assign | expr_stmt
funcdef     = 'fn' kw ws name:ident ws '(' ws (params:ident (ws ',' ws params:ident)*)? ws ')' ws body:block  -> FuncDef
block       = '{' ws (stmt ws)* '}'                                   -> list
while_stmt  = 'while' kw ws cond:expr ws body:block                   -> While
if_stmt     = 'if' kw ws cond:expr ws then:block (ws 'else' kw ws else_:block)?  -> If
return_stmt = 'return' kw (ws value:expr)? ws ';'                     -> Return
break_stmt  = 'break' kw ws ';'                                       -> Break()
let_stmt    = 'let' kw ws name:ident ws '=' ws value:expr ws ';'      -> Let
assign      = name:ident ws '=' !'=' ws value:expr ws ';'             -> Assign
@silent expr_stmt = expr ws ';'

@left expr "expression" = left:sum (ws op:cmpop ws right:sum)?        -> BinOp
@left sum  "expression" = left:term (ws op:addop ws right:term)*      -> BinOp
@left term "expression" = left:operand (ws op:mulop ws right:operand)*  -> BinOp
@silent operand = neg | primary
neg         = '-' ws operand:operand                                  -> Neg
@silent primary = number | string | call | ident | '(' ws expr ws ')'
call        = name:ident ws '(' ws (args:expr (ws ',' ws args:expr)*)? ws ')'  -> Call

number      = [0-9]+ ('.' [0-9]+)?                                    -> float
string      = '"' ('\\' . | [^"\\])* '"'                              -> unquote
ident "name"       = !keyword [a-zA-Z_] [a-zA-Z0-9_]*                 -> Name
cmpop "operator"   = '==' | '!=' | '<=' | '>=' | '<' | '>'            -> str
addop "operator"   = [+\-]                                            -> str
mulop "operator"   = [*/%]                                            -> str

@silent keyword = ('fn' | 'while' | 'if' | 'else' | 'return' | 'break' | 'let') kw
@silent kw      = ![a-zA-Z0-9_]
@silent ws      = ([ \t\n\r] | '#' [^\n]*)*
"""


# ── AST ──


@dataclass
class Program:
    body: list


@dataclass
class FuncDef:
    name: "Name"
    params: list
    body: list


@dataclass
class While:
    cond: object
    body: list


@dataclass
class If:
    cond: object
    then: list
    else_: list | None


@dataclass
class Return:
    value: object


@dataclass
class Break:
    pass


@dataclass
class Let:
    name: "Name"
    value: object


@dataclass
class Assign:
    name: "Name"
    value: object


@dataclass
class BinOp:
    left: object
    op: str
    right: object


@dataclass
class Neg:
    operand: object


@dataclass
class Call:
    name: "Name"
    args: list


@dataclass
class Name:
    text: str


PARSER = zgram.compile(GRAMMAR, ast=sys.modules[__name__])

# ── Static rules ──

RULES = Rules(
    PARSER,
    [
        inside("Break", within="While", stop_at="FuncDef", code="break-outside-loop", message="'break' outside loop"),
        inside("Return", within="FuncDef", code="return-outside-function", message="'return' outside function"),
        forbid("FuncDef FuncDef", code="nested-function", message="functions cannot be defined inside functions"),
        # One namespace: variables, parameters and functions. A function's
        # own name belongs to the scope outside it and is visible before its
        # definition; everything else is visible from its definition on.
        scopes(
            scope=("Program", "FuncDef"),
            define=("Let > .name", "FuncDef > .params"),
            define_outer="FuncDef > .name",
            use="Name",
            hoist="FuncDef > .name",
            after="Let > .name",  # `let a = a;` does not see the new `a`
            builtins=("print",),
        ),
    ],
)


def function_of(symbol, ctx):
    """The funcdef node a symbol names, or None if it is a variable, a
    parameter or a builtin."""
    if symbol.builtin:
        return None
    name = ctx.tree.node(symbol.node)
    return name.parent() if name.field() == "name" and name.parent().rule() == "funcdef" else None


@RULES.rule("Call", code="arity")
def check_call(call, ctx):
    symbol = ctx.resolve(call.get("name"))
    if symbol is None or symbol.builtin:
        return  # undefined names are reported by scopes(); builtins take anything
    func = function_of(symbol, ctx)
    if func is None:
        ctx.error(call.get("name"), f"'{symbol.name}' is not a function", code="not-a-function")
        return
    expected, got = len(func.get_all("params")), len(call.get_all("args"))
    if expected != got:
        ctx.error(call, f"{symbol.name}() takes {expected} argument{'s' * (expected != 1)}, got {got}")


@RULES.rule("Name:not(.name)", code="function-as-value")
def check_value(name, ctx):
    symbol = ctx.resolve(name)
    if symbol is not None and (symbol.builtin or function_of(symbol, ctx) is not None):
        ctx.error(name, f"function '{symbol.name}' used as a value")


# ── Interpreter ──


class TinyError(Exception):
    """A runtime error; `.diagnostic` says where."""

    def __init__(self, node, code, message):
        self.diagnostic = zgram.Diagnostic("error", code, message, getattr(node, "__zspan__", (0, 0)))
        super().__init__(message)


class _Break(Exception):
    pass


class _Return(Exception):
    def __init__(self, value):
        self.value = value


OPERATORS = {
    "+": lambda a, b: a + b,
    "-": lambda a, b: a - b,
    "*": lambda a, b: a * b,
    "/": lambda a, b: a / b,
    "%": lambda a, b: a % b,
    "==": lambda a, b: a == b,
    "!=": lambda a, b: a != b,
    "<": lambda a, b: a < b,
    "<=": lambda a, b: a <= b,
    ">": lambda a, b: a > b,
    ">=": lambda a, b: a >= b,
}


class Interpreter:
    """Runs a checked program. Names were resolved by zrules: a variable is
    looked up by its Symbol, in the globals or in the current call's frame."""

    def __init__(self, program, analysis, output=print):
        self.symbol = analysis.resolve
        self.globals = {}
        self.frame = self.globals
        self.builtins = {"print": lambda *args: output(*[format_value(a) for a in args])}
        self.functions = {self.symbol(s.name): s for s in program.body if isinstance(s, FuncDef)}
        self.program = program

    def run(self):
        self.block(self.program.body)

    def block(self, stmts):
        for stmt in stmts:
            self.exec(stmt)

    def slot(self, symbol):
        """The dict a variable lives in: globals, or the running call's frame."""
        return self.globals if symbol.scope == 0 else self.frame

    def exec(self, node):
        match node:
            case FuncDef():
                pass
            case Let(name, value) | Assign(name, value):
                symbol = self.symbol(name)
                self.slot(symbol)[symbol] = self.eval(value)
            case If(cond, then, else_):
                if self.eval(cond):
                    self.block(then)
                elif else_ is not None:
                    self.block(else_)
            case While(cond, body):
                try:
                    while self.eval(cond):
                        self.block(body)
                except _Break:
                    pass
            case Break():
                raise _Break
            case Return(value):
                raise _Return(None if value is None else self.eval(value))
            case _:
                self.eval(node)

    def eval(self, node):
        match node:
            case float() | str():  # literals: built by `-> float` and `-> unquote`
                return node
            case Name():
                symbol = self.symbol(node)
                try:
                    return self.slot(symbol)[symbol]
                except KeyError:
                    # The one name error left for run time: defined, but not yet assigned
                    raise TinyError(node, "unassigned", f"'{node.text}' is used before it has a value") from None
            case Neg(operand):
                value = self.eval(operand)
                if not isinstance(value, float):
                    raise TinyError(node, "type-mismatch", f"cannot negate {type_name(value)}")
                return -value
            case BinOp(left, op, right):
                a, b = self.eval(left), self.eval(right)
                try:
                    return OPERATORS[op](a, b)
                except ZeroDivisionError:
                    raise TinyError(node, "division-by-zero", "division by zero") from None
                except TypeError:
                    raise TinyError(node, "type-mismatch", f"cannot apply '{op}' to {type_name(a)} and {type_name(b)}") from None
            case Call(name, args):
                symbol = self.symbol(name)
                values = [self.eval(a) for a in args]
                if symbol.builtin:
                    return self.builtins[symbol.name](*values)
                func = self.functions[symbol]
                saved, self.frame = self.frame, {self.symbol(p): v for p, v in zip(func.params, values)}
                try:
                    self.block(func.body)
                except _Return as e:
                    return e.value
                finally:
                    self.frame = saved
                return None
        raise TinyError(node, "internal", f"cannot evaluate {type(node).__name__}")


def type_name(value):
    return {float: "number", str: "string", bool: "boolean", type(None): "nothing"}.get(type(value), type(value).__name__)


def format_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return "nothing" if value is None else str(value)


def run(source, filename="<tiny>", output=print, errors=None):
    """Check and run a program. Returns True, or False after reporting diagnostics."""
    errors = errors or (lambda text: print(text, file=sys.stderr))
    try:
        tree = PARSER.parse_tree(source)
    except zgram.ParseError as e:
        errors(e.diagnostic.render(source, filename))
        return False
    analysis = RULES.analyze(tree)
    for diagnostic in analysis.diagnostics:
        errors(diagnostic.render(source, filename))
    if not analysis.ok:
        return False
    try:
        Interpreter(tree.root.to_ast(), analysis, output).run()
    except TinyError as e:
        errors(e.diagnostic.render(source, filename))
        return False
    return True


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python tiny.py program.tiny")
    with open(sys.argv[1], encoding="utf-8") as f:
        sys.exit(0 if run(f.read(), sys.argv[1]) else 1)
