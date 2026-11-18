// `x.copy()` on a COPY type whose `@copy` constructor is `@deprecated` is
// an explicit copy: SC354W, the warning for a copy nothing in the source
// names, is not raised for it, nor for a copy made through a
// `T impl Copyable` bound. The implicit copy beside them is still
// reported, with no `.copy()` fix-it: the type has no `copy` of its own,
// and `.copy()` on it runs the constructor the warning is about.

var copies: i32 = 0

class Old {
    pub var n: i32

    pub fn Old(self, n: i32) {
        self.n = n
    }

    @deprecated("build a new one")
    @copy pub fn Old(self, const other: Self) {
        self.n = other.n
        copies += 1
    }
}

fn <T impl Copyable> dup(const x: T) -> T {
    return x.copy()
}

fn main() -> i32 {
    var a = Old(4)
    var b = a.copy()
    var c = dup(a)
    var d = copy(a)
    if copies != 3 || b.n + c.n + d.n != 12 {
        return 1
    }

    var e = a
    // CHECK: [[@LINE-1]]:13: warning [SC354W]: implicit copy of a 'Old', whose copy constructor is deprecated
    // CHECK-NOT: fix-it
    // CHECK-NOT: warning
    if copies != 4 || e.n != 4 {
        return 2
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %overlay_builtins %t.lib base/copy.k=%S/inputs/copy.k
// RUN: { %kairo_overlay --builtins-dir=%t.lib/builtin %s --type-check-only 2>&1 || true; } | %FileCheck %s

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo_overlay --builtins-dir=%t.lib/builtin %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD
// BUILD:     warning [SC354W]
// BUILD-NOT: {{warning|error}}
// RUN: %t.exe
