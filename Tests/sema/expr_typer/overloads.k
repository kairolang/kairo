// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Overload resolution (ExprTyper / OverloadResolution).
//
// Ranks are Exact / Converted / None, and a rank is NOT ordered inside
// itself: two candidates that both reach Exact are ambiguous, and the fix is
// to say which one was meant. An untyped literal reaches Exact against every
// type it fits, so `f(1)` against an integer AND a float overload is
// ambiguous by that rule -- see `lit_is_exact_against_both` below, which is
// the case a reader is most likely to be surprised by.
//
// A generic candidate loses to a non-generic one that ranks the same: the
// concrete signature was written for this call, the template for any call.

fn f(x: i32) -> i32 { return x }
fn f(x: f64) -> f64 { return x }
fn f(x: u8, y: u8) -> u8 { return x }

fn gen(x: i32) -> i32 { return x }
fn <T> gen(x: T) -> T { return x }

fn defaulted(x: i32, y: i32 = 5) -> i32 { return x + y }

class Box {
    pub var v: i32 = 0;
    fn get(self) -> i32 { return self.v }
    fn set(self, n: i32) -> i32 { return n }
    fn set(self, n: f64) -> f64 { return n }
}

fn selection(b: *Box) {
    var by_float = f(1.5);        // Float literal: only f(f64) is viable
    var by_arity = f(1u8, 2u8);   // arity picks the two-parameter overload
    var concrete = gen(1);        // non-generic beats the generic at equal rank
    var omitted  = defaulted(1);  // the default fills y
    var named    = defaulted(y: 9, x: 1);
    var method   = b->get();      // through the receiver
    var by_arg   = b->set(1.5);   // the f64 overload of a method
}

fn lit_is_exact_against_both() {
    var a = f(1);
}

fn no_such_overload(s: *Box) {
    var a = f(s);
}

// DIAG: error{{.*}}call to 'f' is ambiguous: more than one candidate matches at the same rank
// DIAG: note{{.*}}candidate declared here
// DIAG: note{{.*}}candidate declared here
// DIAG: note{{.*}}conversions are not ordered within a rank; cast one argument to make the choice explicit
// DIAG: error{{.*}}no matching overload for call to 'f'

// SEMA: -- inferred decls --
// SEMA:      by_float : f64
// SEMA-NEXT: by_arity : u8
// SEMA-NEXT: concrete : i32
// SEMA-NEXT: omitted : i32
// SEMA-NEXT: named : i32
// SEMA-NEXT: method : i32
// SEMA-NEXT: by_arg : f64
