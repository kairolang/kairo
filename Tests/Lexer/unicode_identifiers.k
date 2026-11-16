// An identifier is a Unicode XID_Start character (or `_`, `#`, an ASCII
// letter) followed by XID_Continue characters (UAX #31), read from the
// compiler's own tables: the same on every host. A combining mark and a
// non-ASCII digit continue a name; White_Space characters separate tokens.

fn main() -> i32 {
    var année = 1
    var Ω = 2
    var 变量 = 3
    var été = 4
    var x٣ = 5
    var ª = 6
    var 𐊀 = 7
    var nbsp = 8
    var　wide = 9
    return année + Ω + 变量 + été + x٣ + ª + 𐊀 + nbsp + wide - 45
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
