// Bug #6 repro: value argument in a generic (type-position) argument list.
// `12` is a value, not a type. Before the fix the parser rejected it with
// `S053E: expected type, found 'integer'` and silently dropped the arg
// (printing `Array<i32>`). Now the generic-arg parser falls through to
// `_parse_type_expr`, wrapping the value in a `TypeExpr`, so it parses and
// round-trips through `--print-ast=tree`.
var a: Array<i32, 12> = foo()
var b: Array<i32, 12, 34> = bar()
var c: Vec<i32> = baz()          // plain type arg still works
