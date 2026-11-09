// A member signature naming `Holder::Inner` is spelled through Holder in
// C++, which must be complete at that declaration. User sits ahead of Holder
// in the source, so the plan must still emit Holder's definition first
// ("incomplete type named in nested name specifier").

class User {
    pub fn take(self, p: unsafe *Holder::Inner) -> i32 { return (*p).v; }
}
class Holder {
    pub class Inner { pub var v: i32 = 7; }
    pub var in_: Inner = Inner();
}
fn main() -> i32 {
    var h = Holder();
    var u = User();
    return u.take(unsafe &h.in_)
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: CL001E
// DIAG-NOT: I003E
// RUN: %t.exe; test $? -eq 7
