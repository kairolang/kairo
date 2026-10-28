// Every rule WhereGuardCheck holds a `where` dispatch group to (where.mdx),
// and the two RedeclMerge and the parser keep. Three compiles of this file:
// the checks (lines ending in a tag blanked, so every line number holds),
// the redeclaration errors that stop Sema before the checks (`[redecl]`),
// and the parse errors that stop it before anything (`[parse]`).

// --- fallback --------------------------------------------------------------

fn sq(x: f64) -> f64 where x >= 0.0 { return x }

// Guards that cover every value are a fallback; so is `true`.
fn sign(x: i32) -> i32 where x >= 0 { return 1 }
fn sign(x: i32) -> i32 where x < 0  { return -1 }
fn always(x: i32) -> i32 where true { return x }

// A different parameter type is another overload, not a member: this
// group of one has no fallback.
fn ov(x: i32) -> i32 where x > 1 { return 2 }
fn ov(x: f64) -> i32 { return 3 }

// --- unreachable and overlapping guards ------------------------------------

fn process(x: i32) -> i32 where x > 50  { return 2 }
fn process(x: i32) -> i32 where x > 100 { return 3 }
fn process(x: i32) -> i32 { return 1 }

fn handle(x: i32) -> i32 where x > 0 && x < 100 { return 1 }
fn handle(x: i32) -> i32 where x > 50 { return 2 }
fn handle(x: i32) -> i32 { return 3 }

// Covered by the two before it together, not by either alone.
fn split(x: i32) -> i32 where x < 0 { return 1 }
fn split(x: i32) -> i32 where x >= 0 && x <= 9 { return 2 }
fn split(x: i32) -> i32 where x > -5 && x < 5 { return 3 }
fn split(x: i32) -> i32 { return 4 }

fn never(x: i32) -> i32 where x > 5 && x < 3 { return 1 }
fn never(x: i32) -> i32 { return 0 }

// An earlier guard inside a later one is the priority idiom: silent. So is
// every guard the procedure does not decide (a float, a call).
fn tiers(x: i32) -> i32 where x > 100 { return 2 }
fn tiers(x: i32) -> i32 where x > 0   { return 1 }
fn tiers(x: i32) -> i32 { return 0 }
fn temp(t: f64) -> i32 where t > 100.0 { return 2 }
fn temp(t: f64) -> i32 where t > 200.0 { return 3 }
fn temp(t: f64) -> i32 { return 0 }

// --- what may not be guarded ----------------------------------------------

fn uns(x: i32) unsafe -> i32 where x > 1 { return 2 }

fn nobody(x: i32) -> i32 where x > 1
fn nobody(x: i32) -> i32 { return 0 }

interface Validator {
    fn validate(self, input: i32) -> bool
      where input > 0
}

// --- members must agree ---------------------------------------------------

fn rt(x: i32) -> i32 where x > 1 { return 2 }
fn rt(x: i32) -> i64 { return 3 }

class C {
    pub var n: i32
    fn c1(self, k: i32) -> i32 where k > 0 { return 1 }
    fn c1(const self, k: i32) -> i32 { return 0 }

    virtual fn v(self, k: i32) -> i32 where k > 0 { return 1 }
    virtual fn v(self, k: i32) -> i32 { return 0 }
}

// --- not yet supported (SC116E) -------------------------------------------

// (A 'panic' member is supported since P6: the dispatcher's set is the
// union of its members'. Codegen/panic/where.k runs one.)

fn dflt(x: i32, y: i32 = 2) -> i32 where x > 1 { return y }
fn dflt(x: i32, y: i32) -> i32 { return 3 }

fn <T> gen(x: T) -> i32 where true { return 2 }

// --- redeclaration (stops Sema before the checks) -------------------------

fn two(x: i32) -> i32 { return 1 }                 // [redecl]
fn two(x: i32) -> i32 where x > 1 { return 2 }     // [redecl]
fn two(x: i32) -> i32 { return 3 }                 // [redecl]

// An unsafe overload never joins the group; beside the fallback it is the
// unsafe-overload rule's today (R039E: unsafe overloads cannot coexist yet).
fn ua(x: i32) -> i32 where x > 1 { return 2 }      // [redecl]
fn ua(x: i32) -> i32 { return 3 }                  // [redecl]
fn ua(x: i32) unsafe -> i32 { return 4 }           // [redecl]

// --- parse errors (stop everything) ---------------------------------------

class <T> Buffer                                   // [parse]
  where sizeof T <= 128 {                          // [parse]
    var data: T                                    // [parse]
}                                                  // [parse]

fn use_closure() -> i32 {                          // [parse]
    var c = fn (x: i32) -> i32 where x > 0 { return x }   // [parse]
    return c(1)                                    // [parse]
}                                                  // [parse]

// --- lit wiring -----------------------------------------------------------
// RUN: sed 's|.*// \[redecl\]$||; s|.*// \[parse\]$||' %s > %t.check.k
// RUN: { %kairo %t.check.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=CHECK --implicit-check-not="error [" --implicit-check-not="warning ["
//
// CHECK:     :9:1: error [SC001E]: no fallback overload for 'sq' when where condition fails
// CHECK-NEXT: :9:1: note [SC001N]: add an overload without a 'where' clause to handle all remaining cases
// CHECK:     :18:1: error [SC001E]: no fallback overload for 'ov' when where condition fails
// CHECK-NEXT: :18:1: note [SC001N]: add an overload without a 'where' clause to handle all remaining cases
// CHECK:     :24:33: warning [SC001W]: 'where' guard of 'process' is unreachable: every value it accepts is taken by an earlier overload
// CHECK-NEXT: :23:33: note [SC001N]: this guard is tested first
// CHECK:     :28:32: warning [SC001W]: 'where' guard of 'handle' overlaps an earlier one; a value both accept goes to the earlier overload
// CHECK-NEXT: :27:32: note [SC001N]: overlaps this guard, which is tested first
// CHECK:     :34:31: warning [SC001W]: 'where' guard of 'split' is unreachable: every value it accepts is taken by an earlier overload
// CHECK-NEXT: :33:31: note [SC001N]: this guard is tested first
// CHECK:     :37:31: warning [SC001W]: 'where' guard of 'never' never holds, so this overload is never called
// CHECK:     :51:36: error [SC001E]: 'where' is not allowed on an 'unsafe' overload of 'uns'
// CHECK-NEXT: :51:1: note [SC001N]: unsafe overloads are a separate namespace, selected with 'unsafe' at the call; they take no part in 'where' dispatch
// CHECK:     :53:32: error [SC001E]: a guarded overload of 'nobody' needs a body; the guard chooses which body runs
// CHECK:     :58:13: error [SC001E]: 'where' is not allowed on an interface method; interfaces are zero-cost, so a requirement cannot dispatch at run time. Use 'requires' for a compile-time constraint
// CHECK-NEXT: :56:1: note [SC001N]: the interface is declared here
// CHECK:     :64:1: error [SC001E]: every overload in the 'where' dispatch of 'rt' must have the same return type; C++ sees them as one function
// CHECK-NEXT: :63:1: note [SC001N]: the first overload of the dispatch is here
// CHECK:     :69:5: error [SC001E]: every overload in the 'where' dispatch of 'c1' must have the same 'const self'; C++ sees them as one function
// CHECK-NEXT: :68:5: note [SC001N]: the first overload of the dispatch is here
// CHECK:     :71:5: error [SC116E]: 'where' dispatch on a 'virtual' or 'override' method is not yet supported
// CHECK:     :72:5: error [SC116E]: 'where' dispatch on a 'virtual' or 'override' method is not yet supported
// CHECK:     :80:1: error [SC116E]: 'where' dispatch on a default argument is not yet supported
// CHECK:     :83:1: error [SC116E]: 'where' dispatch on a generic function is not yet supported

// The full compile stops at the same diagnostics: nothing reaches the
// lowering.
// RUN: { %kairo %t.check.k -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=CHECK --implicit-check-not="error [" --implicit-check-not="warning ["

// RUN: sed 's|.*// \[parse\]$||' %s > %t.redecl.k
// RUN: { %kairo %t.redecl.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=REDECL --implicit-check-not="error [" --implicit-check-not="warning ["
//
// REDECL:     :89:1: error [R029E]: redefinition of 'two'
// REDECL-NEXT: :87:1: note [R029N]: previous definition of 'two' is here
// REDECL:     :95:1: error [R039E]: 'ua' redeclared with a different 'unsafe' qualifier; the parameter types are identical, so this is one function
// REDECL-NEXT: :94:1: note [R039N]: previously declared here
// REDECL:     :95:1: error [R029E]: redefinition of 'ua'
// REDECL-NEXT: :94:1: note [R029N]: previous definition of 'ua' is here

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=PARSE --implicit-check-not="error [" --implicit-check-not="warning ["
//
// PARSE:     :100:3: error [S045E]: 'where' is not allowed on a class; runtime-conditional dispatch is only valid on functions. Use 'requires' for a compile-time constraint instead
// PARSE-NEXT: fix-it:"{{.*}}":{100:3-100:8}:"requires"
// PARSE:     :105:32: error [S045E]: 'where' is not allowed on a closure; a guard selects among overloads of a named function, and a closure has none. Test the condition with an 'if' in the body instead
