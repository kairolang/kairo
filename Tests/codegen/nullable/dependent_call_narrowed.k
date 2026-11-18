// A nullable proven non-null, passed to a call only the instance resolves
// (a duck call through `self.dyn()`), goes out as its value: the
// instance's parameter is a plain `*P`, and the `*P?` reached C++ as a
// Nullable clang could not convert (found with dyn_cast<T>
// returning `*T?`). Where the instance's parameter is the nullable after
// all, the value converts back.

class P { var k: i32 = 3 }

class <D: type> Mixin {
    fn dyn(self) -> *D { return unsafe ((unsafe &self) as unsafe *D) }
    fn go(self, x: *P?) -> i32 {
        if x == &null { return 100 }
        return self.dyn()->take(x) + self.dyn()->take_opt(x)
    }
}

class V derives Mixin<V> {
    fn take(self, p: *P) -> i32 { return p->k }
    fn take_opt(self, p: *P?) -> i32 { return if (p?) => (p->k * 10) else => 0 }
}

fn main() -> i32 {
    var p = P()
    var v = V()
    return v.go(&p) + v.go(&null)          // 33 + 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 133
