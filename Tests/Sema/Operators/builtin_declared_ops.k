// Every operator a builtin type declares resolves through the ordinary
// record path (RESOLUTION.md, "A builtin type's declared operator wins"):
// binary, comparison and containment `in` on `string` and `[T]`, declared
// here through extensions because Lib/builtin declares none and is not this
// test's to change. builtin_ops_fallback.k covers a builtin that declares
// nothing applicable; `op []` cannot be an extension member (SC055E), so
// builtin_declared_subscript.k declares one in a fixture builtin root.

extend string {
    fn op == (self, o: string) -> bool { return self.len == o.len }
    fn op + (self, o: string) -> i32 { return (self.len + o.len) as i32 }
    fn op in (self, b: u8) -> bool {
        var i: usize = 0
        while i < self.len {
            if self.data[i] == b { return true }
            i = i + 1
        }
        return false
    }
}

extend <T: type> [T] {
    fn op in (self, x: T) -> bool {
        var i: usize = 0
        while i < self.len {
            if self.data[i] == x { return true }
            i = i + 1
        }
        return false
    }
}

fn has(v: [i32], x: i32) -> bool { return x in v }

fn main() -> i32 {
    var r: i32 = 0
    if "ab" == "cd" { r += 1 }                  // same length: true
    if "ab" != "abc" { r += 2 }                 // derived from op ==
    r += "abc" + "de"                           // 5
    var b: u8 = 98
    var z: u8 = 122
    if b in "abc" { r += 8 }
    if z in "abc" { r += 100 }
    return r                                    // 1 + 2 + 5 + 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 16
