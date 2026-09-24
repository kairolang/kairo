// Named arguments and the pack: placement, and the four ways it can be wrong.
//
// `s` is the pack, so `end` and `spacing` follow it and are KEYWORD-ONLY --
// every positional argument from `s` onward belongs to `s`, so no argument
// count would ever reach them. Both have defaults, which is what lets the four
// accepting calls below differ only in which names they supply.
//
// A parameter WITHOUT a default is allowed to follow one WITH a default (see
// `g`), so a satisfied parameter list says nothing about the slots around it.

fn print(const ...s: string, end: char = '\n', const spacing: char = ' ') { }

fn g(const ...s: string, n: i32) { }

fn ok() {
    // Positional only: both keyword-only parameters take their defaults.
    // arg_map [0 (pack_len 2), -1, -1]
    print("hi", "there")

    // arg_map [0 (2), 2, -1]
    print("hi", "there", end: ' ')

    // arg_map [0 (2), -1, 2]
    print("hi", "there", spacing: '\n')

    // Both, written in the opposite order to the parameter list: a named
    // argument is matched by NAME, so its position among the named ones is not
    // part of the meaning. arg_map [0 (2), 3, 2]
    print("hi", "there", spacing: '\n', end: ' ')
}

fn bad_positional() {
    // `end` is keyword-only. The char cannot join the pack (`string`) but WOULD
    // fit `end`, so the error names the parameter rather than reporting a
    // conversion failure against the pack.
    print("hi", "there", ' ')
}

fn bad_twice() {
    print("hi", "there", end: ' ', end: ' ')
}

fn bad_name() {
    print("hi", "there", nd: ' ')
}

fn bad_missing() {
    // `n` has no default and no argument reaches it.
    g("hi")
}

fn bad_interleaved() {
    // A named argument between two pack arguments: arg_map records the pack as
    // a first index plus a length, and this puts a non-member inside that run.
    print("hi", spacing: '\n', "there")
}

// --- lit wiring -----------------------------------------------------------
// At the BOTTOM: every DIAG line below names a line number in the code above,
// so anything inserted before `fn print` invalidates all of them.

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG

// The four accepting calls contribute nothing: `ok` is above every rejection,
// so a diagnostic from it is output before the first DIAG match. A DIAG-NOT
// only checks the span before the NEXT positive match, so it has to sit here,
// above the first DIAG; below the last one it checked nothing of ok().
// DIAG-NOT: error

// Each call has exactly one candidate, so the rule that rejected it IS the
// error, reported at the call and naming the parameter. With an overload set
// the same reasons stay notes under "no matching overload" instead.
// DIAG: named_args.k:36:5: error [SC018E]: parameter 'end' can only be given by name; it follows a pack, so this argument joins the pack instead
// DIAG: named_args.k:40:5: error [SC020E]: parameter 'end' was already given
// DIAG: named_args.k:44:5: error [SC019E]: no parameter named 'nd'
// DIAG: named_args.k:49:5: error [SC021E]: missing argument for parameter 'n'
// DIAG: named_args.k:55:5: error [SC022E]: a named argument cannot appear between two pack arguments; move it after them

// The tree: `...` sits on the parameter that CARRIES it, not on the last one,
// and a `name: value` argument is a NamedArgExpr rather than an assignment
// wearing a `:`.
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST-DAG: ParamDecl ...s: string
// AST-DAG: NamedArgExpr end:
// AST-DAG: NamedArgExpr spacing:
// AST-NOT: AssignOperatorExpr
