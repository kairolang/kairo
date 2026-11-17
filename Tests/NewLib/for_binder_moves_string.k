// `string` is a MOVE type in this library and `split` yields one piece per
// step: a plain binder takes each piece by move, and can hand it on.
fn total(s: string) -> usize {
    return s.size()
}

fn main() -> i32 {
    var n: usize = 0
    for piece in "a,b".split(",") {
        n += total(piece)
    }

    return n as i32 - 2
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: { %kairo_new %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:   error [
// CHECK-LABEL: int main() noexcept {
// CHECK:       string piece = static_cast<{{ ?}}::builtin::string::string &&>((* __kairo_it{{[0-9]+}}.current()));
// CHECK:       total(static_cast<{{ ?}}::builtin::string::string &&>(piece))
