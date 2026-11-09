// RUN: %kfmt --stdout %s | diff -u %S/Expected/try_expr.k -
// RUN: %kfmt --check %S/Expected/try_expr.k
//
// Rule 8.3 (decided 2026-11-08): a `try` expression stays on one
// line while it fits; otherwise each `catch` starts a line in the `try`'s
// column, and the `=>` of the arms line up.

fn f(path: string, opts: Options) -> i32 {
    var s = try parse(path) catch => 0
    var n = try parse_config_file(path, opts)
            catch e: ParseError => -1
            catch e: IoError    => -2
            catch               => 0
    return try load_everything_from(path, opts, more) catch e: ParseError => -1 catch => 0
}
