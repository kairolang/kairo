// O22: a construction through a duck `<T: type>` alias (`type G = T::Guard;
// G(x)`) is wrapped in the no-panic check. The check must not move the
// constructed value: `operator,` returned it by value from `T&&`, so a guard
// with deleted copy AND move failed to compile (and a movable one ran its
// destructor twice). The construction now stays a prvalue.

ffi "c++" import "duck_construct_no_move.h"

class Host derives Mixin<Host> {
    pub var pos: i32 = 0;
    type Guard = NoMoveGuard;
}

class <T: type> Mixin {
    inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    pub fn ahead(self) -> bool {
        type G = T::Guard;
        var t = G(unsafe (&self.dyn()->pos));
        return self.dyn()->pos == 10;
    }
}

fn main() -> i32 {
    var h = Host();
    if !h.ahead() { return 1 }
    if h.pos != 11 { return 2 }
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: %t.exe
