// Malformed declared panic sets (PANIC.md §2.2). Each is one S055E at the
// set, and recovery stops at the rest of the header (`->`, the body), so
// nothing cascades past it: the bodies below still parse and type-check.

class E1 { var a: i32 }

// `panic()` names no type. Fix-it: drop the parentheses, leaving a bare
// `panic` (inferred set), which is also how it parses.
fn empty() panic() -> i32 { return 1 }

// The list never closes before `->`.
fn unclosed() panic(E1 -> i32 { return 2 }

// A token that is not a type.
fn not_a_type() panic(E1, 3) -> i32 { return 3 }

// Two types with no comma.
fn no_comma() panic(E1 E1) -> i32 { return 4 }

// An empty set in a `fn` type and in a closure.
fn in_type(cb: fn() panic() -> i32) { }
fn in_closure() {
    var c = fn () panic() -> i32 { return 5 }
}

fn after_all_of_them() -> i32 { return 6 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      panic_set_errors.k:9:17: error [S055E]: an explicit panic set names at least one error type; a bare 'panic' has its set inferred
// DIAG-NEXT: fix-it:"{{.*}}panic_set_errors.k":{9:17-9:19}:""
// DIAG-NEXT: panic_set_errors.k:12:24: error [S055E]: expected ',' or ')' after a type in the panic set
// DIAG-NEXT: panic_set_errors.k:15:27: error [S053E]
// DIAG-NEXT: panic_set_errors.k:18:24: error [S055E]: expected ',' or ')' after a type in the panic set
// DIAG-NEXT: panic_set_errors.k:21:26: error [S055E]: an explicit panic set
// DIAG-NEXT: fix-it:
// DIAG-NEXT: panic_set_errors.k:23:24: error [S055E]: an explicit panic set
// DIAG-NEXT: fix-it:
// DIAG-NOT:  error [
