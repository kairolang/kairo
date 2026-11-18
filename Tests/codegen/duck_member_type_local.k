// `var u: T::Guard;` under a duck `<T: type>` is spelled `typename T::Guard`
// (it is never left unresolved at codegen).

class Host derives Mixin<Host> {
    pub var pos: i32 = 0;
    class Guard {
        priv var q: unsafe *Host;
        fn Guard(self) { self.q = unsafe (&null); }
    }
}
class <T: type> Mixin {
    pub fn ahead(self) -> bool {
        var u: T::Guard;
        return true;
    }
}
fn main() -> i32 {
    var h = Host();
    if !h.ahead() { return 1 }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: { %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: I011W
// DIAG-NOT: I003E
// RUN: %t.exe
// A `: type` parameter is rejected unless duck generics are enabled.
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --check-prefix=GATE
// GATE: error [SC198E]: 'T: type' needs -fduck-generics
