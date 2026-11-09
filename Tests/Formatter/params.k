// RUN: %kfmt --stdout %s | diff -u %S/Expected/params.k -
// RUN: %kfmt --check %S/Expected/params.k
//
// Rules 4.1 / 6.2: parameters that do not fit take the aligned form, the
// first one on the `fn f(` line, `:` glued to each name and the types in
// one column; `) -> Ret {` follows the last one. When the aligned column
// leaves too little room the block form is the fallback (proposed). Rule
// 12.4: a trailing comment stays on the declaration's first line.

fn create_session(config: *SessionConfig, diag: *DiagnosticsEngine, sources: *SourceManager, opts: *Options) -> *Session {
    return &null;
}

fn example(item1: i32, item2: i32, item3: i32, item4: i32, item5_long_name: i32, item_the_last: i32) { }   // hello mate

fn a_function_with_a_rather_long_name_to_push_the_column(first_parameter: SomeVeryLongTypeName<WithArgs>, second: i32) {
}

fn fits(a: i32, b: i32 = 0) -> i32 { return a; }
