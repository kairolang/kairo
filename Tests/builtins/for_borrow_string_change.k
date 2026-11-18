// A plain binder over a vector of strings borrows each string read-only:
// appending to it is refused, and the note offers a local copy or `*s`.
fn main() -> i32 {
    var names: [string]
    names.push("ab")
    for s in names {
        s += "x"
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: { %kairo_new %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      :7:9: error [SC{{[0-9]+}}E]: {{.*}}
// CHECK:      :6:9: note [I900N]: the binder 's' borrows its element in place, read-only, because 'string' cannot be copied; bind a local to change a copy, 'var mine = s.copy()', or bind '*s' in a 'for' to change the element in place
