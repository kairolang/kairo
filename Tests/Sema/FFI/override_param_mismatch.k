// SI8: `override` follows C++'s rule. A Kairo `x: D` is a by-value `D`, so
// it does not override a C++ `virtual f(const D&)`: Kairo reports it rather
// than leaving clang's "marked 'override' but does not override". The
// `const x: D` form (`const D&`) and a by-value match both override.
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: error
// CHECK: override_param_mismatch.k:[[@LINE+13]]:{{[0-9]+}}: error [SC001E]: 'handle' is marked 'override' but overrides nothing
// CHECK: si8_override.h:5:{{[0-9]+}}: note {{.*}}the base method of that name
// CHECK-NOT: error

ffi "c++" import "Inputs/si8_override.h"

class Good derives Base {
    fn Good(self) { }
    override fn handle(self, lvl: i32, const info: D) -> i32 { return info.v * 2 + lvl; }
    override fn take(self, d: D) -> i32 { return d.v + 1; }
}
class Bad derives Base {
    fn Bad(self) { }
    override fn handle(self, lvl: i32, info: D) -> i32 { return info.v * 2 + lvl; }
}

fn main() -> i32 { return 0; }
