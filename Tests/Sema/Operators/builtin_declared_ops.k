// Every operator a builtin type declares resolves through the ordinary
// record path (RESOLUTION.md, "A builtin type's declared operator wins"):
// binary and comparison on `string` (Lib/builtin/string.k declares `op <=>`
// and `op +=`, so `==`, `!=` and `+` are derived from them), and
// containment `in` on `string` and `[T]`, declared here through extensions
// because Lib/builtin declares none. builtin_ops_fallback.k covers a builtin that declares
// nothing applicable; `op []` cannot be an extension member (SC055E), and
// builtin_declared_subscript.k covers the builtins' own.

extend string {
    fn op in (self, b: u8) -> bool {
        var i: usize = 0
        while i < self.length() {
            if self.as_ptr()[i] == b { return true }
            i = i + 1
        }
        return false
    }
}

extend <T: type> [T] {
    fn op in (self, x: T) -> bool {
        var i: usize = 0
        while i < self.size() {
            if self[i] == x { return true }
            i = i + 1
        }
        return false
    }
}

fn has(v: [i32], x: i32) -> bool { return x in v }

fn main() -> i32 {
    var r: i32 = 0
    if "ab" == "cd" { r += 1 }                  // derived from op <=>: false
    if "ab" != "abc" { r += 2 }                 // derived from op <=>
    r += ("abc" + "de").length() as i32         // derived from op +=: 5
    var b: u8 = 98
    var z: u8 = 122
    if b in "abc" { r += 8 }
    if z in "abc" { r += 100 }
    return r                                    // 2 + 5 + 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
