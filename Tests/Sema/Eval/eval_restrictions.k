// eval.mdx's restriction table, in an eval context -- an `eval fn` body or
// an `eval` initializer (EvalUsageChecking, EVAL.md §6): only eval calls
// (a fix-it adds `eval` to the user's callee, constructor included), no
// pointer parameter, local or `&` / `*`, no local with a destructor, no
// non-eval global (a fix-it for a `const`), no run-time local in an
// initializer, no `where`. An eval fn's own locals and loops are fine.
var counter = 3
const RUNTIME = 4
fn plain(x: i32) -> i32 { return x }
class Res { pub var v: i32  fn op delete(self) { } }
class Pt { pub var x: i32  pub var y: i32  fn Pt(self, x: i32) { self.x = x  self.y = 0 } }
eval fn bad1(p: *i32) -> i32 { return 1 }
eval fn bad2(x: i32) -> i32 {
    var r = Res()
    var q = &x
    return plain(x) + counter + RUNTIME
}
eval fn bad3() -> i32 where true { return 1 }
eval A = plain(3)
eval B = Pt(1).x
eval fn ok(x: i32) -> i32 { var t = x * 2  for var k = 0; k < 3; ++k { t += k }  return t }
eval C = ok(2)
fn main() -> i32 {
    var n = 2
    eval L = n + 1
    return C
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_restrictions.k:12:14: error [SC001E]: an 'eval' function cannot take a pointer; 'p' is '*i32': there is no addressable memory at compile time
// CHECK: eval_restrictions.k:14:9: error [SC001E]: 'r' is a 'Res', whose destructor is not trivial; it cannot live in an 'eval' function
// CHECK-NEXT: eval_restrictions.k:10:29: note [SC001N]: the destructor is declared here
// CHECK: eval_restrictions.k:15:9: error [SC001E]: an 'eval' function cannot hold a pointer; 'q' is '*i32': there is no addressable memory at compile time
// CHECK: eval_restrictions.k:15:13: error [SC001E]: an eval context cannot take an address or dereference a pointer; there is no addressable memory at compile time
// CHECK: eval_restrictions.k:16:12: error [SC001E]: an eval context can call only 'eval' functions; 'plain' is a function that is not 'eval'
// CHECK-NEXT: fix-it:{{.*}}:{9:1-9:1}:"eval "
// CHECK-NEXT: eval_restrictions.k:9:1: note [SC001N]: 'plain' is declared here
// CHECK: eval_restrictions.k:16:23: error [SC001E]: an eval context reads only compile-time values; 'counter' is a global, static or thread variable that is not 'eval'
// CHECK: eval_restrictions.k:16:33: error [SC001E]: an eval context reads only compile-time values; 'RUNTIME' is a global, static or thread variable that is not 'eval'
// CHECK-NEXT: fix-it:{{.*}}:{8:1-8:6}:"eval"
// CHECK: eval_restrictions.k:18:29: error [SC001E]: an 'eval' function cannot have a 'where' clause; bound 'bad3' with 'requires'
// CHECK: eval_restrictions.k:19:10: error [SC001E]: an eval context can call only 'eval' functions; 'plain' is a function that is not 'eval'
// CHECK: eval_restrictions.k:20:10: error [SC001E]: an eval context can call only 'eval' functions; 'Pt' is a constructor that is not 'eval'
// CHECK-NEXT: fix-it:{{.*}}"eval "
// CHECK: eval_restrictions.k:25:14: error [SC001E]: an eval context reads only compile-time values; 'n' is a run-time local
