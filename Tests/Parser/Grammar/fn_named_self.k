// `self` is a keyword (Lexing.md, keywords table), and a function
// named by any other keyword (`fn class`, `fn while`) or a primitive type
// is S047E. `fn self(self)` and `fn self()` were accepted silently. Now
// the same error; the function is kept under that name, so its signature
// and body still parse and nothing cascades. `self` as the head of a
// qualified name (`fn self::...`) is not this case.

class C {
    fn C(self) {}
    fn self(self) -> i32 { return 1 }
}

fn self() {}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: fn_named_self.k:10:8: error [S047E]: 'self' is a keyword and cannot name a function
// CHECK: fn_named_self.k:13:4: error [S047E]: 'self' is a keyword and cannot name a function
