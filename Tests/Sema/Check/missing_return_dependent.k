// A body that can fall off its end is SC104E whatever it is declared to
// return -- also a DEPENDENT type (`Box<T>::Inner`, a member of a
// dependent instance, which has a canonical since GH#91 and is named in the
// note): it is still a value type, never void and never `!`. The check used to skip any return type without a
// canonical, as if T had already reported it (ticket "Missing return goes
// unreported when the return type is unresolved", 2026-10-27).

class <T> Box {
    class Inner { pub var v: i32 }
    var t: T
}

fn <T> make(b: Box<T>) -> Box<T>::Inner { }
fn <T> made(b: Box<T>) -> Box<T>::Inner { return Box<T>::Inner { v: 1 } }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{error|warning}}
// CHECK: missing_return_dependent.k:13:43: error [SC104E]: 'make' does not return a value on all control paths
// CHECK-NEXT: missing_return_dependent.k:13:27: note [SC104N]: declared to return 'Box<T>::Inner' here; every path must end in 'return', 'panic', or a call that does not return
// CHECK-NOT: {{error|warning}}
