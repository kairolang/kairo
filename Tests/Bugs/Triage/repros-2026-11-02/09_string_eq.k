// Library gap, not a codegen bug: string has no op == (declared in
// Lib/builtin/string.k, not defined). Expected: exit 1.
// Actual: SC066E "no 'op ==' on 'string'; a record compares only through its
// own operator".
fn same(a: string, b: string) -> bool { return a == b }

fn main() -> i32 { return if same("x", "x") => 1 else => 0 }
