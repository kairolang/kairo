// Declaration rules for the `panic` specifier (PANIC.md §2.4, §2.8):
// - `main` can never panic, and nothing may reach it: each unhandled call
//   is an error whose edit handles it or stops with `crash!()`;
// - `panic` with `-> !` is contradictory: a panic returns its error;
// - no constructor (any kind) or destructor can panic (USER 2026-10-27);
// - what is called where no call is written cannot panic, since nothing
//   could handle it there: an `@implicit` conversion, `op panic` itself.
// Each gets an edit removing `panic`.

struct E { var code: i32 }

fn thrower() panic -> i32 { panic E { code: 1 } }

fn fatal() panic -> ! { panic E { code: 2 } }

fn dies() -> ! { crash!() }

class Res {
    var n: i32
    fn Res(self) panic { self.n = thrower() }
    fn Res(self, n: i32) panic { self.n = n }
    @move fn Res(self, other: Res) panic { self.n = other.n }
    fn op delete(self) panic { }
    @implicit fn op as (self) panic -> i32 { return self.n }
    fn op panic (const self) panic -> string { return "res" }
}

fn main() panic -> i32 {
    var a = thrower()
    var b = try thrower() catch => crash!()
    var r = try Res(1) catch => crash!()
    return a + b
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: declarations.k:14:12: error [SC001E]: 'fatal' cannot be both 'panic' and '-> !': a panic returns its error, and '!' never returns
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{14:12-14:17}:""
// CHECK-NEXT: declarations.k:14:1: note [SC001N]: 'fatal' is declared here
// CHECK: declarations.k:20:18: error [SC001E]: a constructor cannot panic: an object is either built whole or not at all
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{20:18-20:23}:""
// CHECK-NEXT: declarations.k:20:5: note [SC001N]: 'Res' is declared here
// CHECK-NEXT: declarations.k:20:5: note [SC001N]: construction that can fail belongs in a static factory function that may panic and returns the object
// CHECK: declarations.k:21:26: error [SC001E]: a constructor cannot panic: an object is either built whole or not at all
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{21:26-21:31}:""
// CHECK-NEXT: declarations.k:21:5: note [SC001N]: 'Res' is declared here
// CHECK-NEXT: declarations.k:21:5: note [SC001N]: construction that can fail belongs in a static factory function that may panic and returns the object
// CHECK: declarations.k:22:36: error [SC001E]: a transfer constructor cannot panic: an object is either built whole or not at all
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{22:36-22:41}:""
// CHECK-NEXT: declarations.k:22:11: note [SC001N]: 'Res' is declared here
// CHECK-NEXT: declarations.k:22:11: note [SC001N]: construction that can fail belongs in a static factory function that may panic and returns the object
// CHECK: declarations.k:23:24: error [SC001E]: a destructor cannot panic: it runs on every exit from the object's scope, where nothing could take an error
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{23:24-23:29}:""
// CHECK-NEXT: declarations.k:23:5: note [SC001N]: 'op delete' is declared here
// CHECK: declarations.k:24:31: error [SC001E]: an '@implicit' conversion cannot panic: it runs where no call is written, so nothing could handle the error
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{24:31-24:36}:""
// CHECK-NEXT: declarations.k:24:15: note [SC001N]: 'op as' is declared here
// CHECK: declarations.k:25:30: error [SC001E]: 'op panic' cannot panic: it runs where no call is written, so nothing could handle the error
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{25:30-25:35}:""
// CHECK-NEXT: declarations.k:25:5: note [SC001N]: 'op panic' is declared here
// CHECK: declarations.k:28:11: error [SC001E]: 'main' cannot panic: nothing above it could handle the error
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{28:11-28:16}:""
// CHECK-NEXT: declarations.k:28:1: note [SC001N]: handle every error in 'main', or stop the program with 'crash!()'
// CHECK: declarations.k:29:13: error [SC001E]: a panic cannot reach 'main': 'thrower' may panic with 'E', which is not handled
// CHECK-NEXT: declarations.k:12:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: declarations.k:29:13: note [SC001N]: or handle it here, or stop the program with 'crash!()'
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{29:13-29:13}:"try "
// CHECK-NEXT: fix-it:"{{.*}}declarations.k":{29:22-29:22}:" catch => crash!()"
