// A `const` binding, or a part of one, passed to a `@move` parameter is
// SC301E at the argument: it cannot be left moved-from. That holds for a
// move-only class, a COPY value and a primitive, a non-generic and a
// generic parameter (std::move included), and a field of a const binding.
// A `var` binding moves as before.

import std

class Res {
    pub var v: i32
    fn Res(self, v: i32) {
        self.v = v
    }

    @move fn Res(self, other: Self) {
        self.v = other.v
    }
}

struct Pair {
    pub var r: Res
}

fn eat(@move r: Res) -> i32 {
    return r.v
}

fn <T> take(@move x: T) -> i32 {
    return 1
}

fn main() -> i32 {
    const a     = Res(1)
    const n     = 5
    const p     = Pair { r: Res(2) }
    var   ok    = Res(3)
    var   total = eat(a)
    total += take(n)
    std::move(a)
    total += eat(p.r)
    total += eat(ok)
    return total
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: const_to_move_param.k:37:23: error [SC301E]: 'a' is const, so it cannot be passed to a '@move' parameter, which leaves its argument moved-from
// CHECK-NEXT: const_to_move_param.k:33:5: note [I900N]: declared const here
// CHECK-NEXT: const_to_move_param.k:38:19: error [SC301E]: 'n' is const, so it cannot be passed to a '@move' parameter, which leaves its argument moved-from
// CHECK-NEXT: const_to_move_param.k:34:5: note [I900N]: declared const here
// CHECK-NEXT: const_to_move_param.k:39:15: error [SC301E]: 'a' is const, so it cannot be passed to a '@move' parameter, which leaves its argument moved-from
// CHECK-NEXT: const_to_move_param.k:33:5: note [I900N]: declared const here
// CHECK-NEXT: const_to_move_param.k:40:18: error [SC301E]: 'p.r' is const, so it cannot be passed to a '@move' parameter, which leaves its argument moved-from
// CHECK-NEXT: const_to_move_param.k:35:5: note [I900N]: declared const here
// CHECK-NOT: error
