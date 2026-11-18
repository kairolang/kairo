// `x as E` for a Kairo enum needs `x` to have exactly E's underlying type:
// the `derives` type, or `u32` when defaulted. Anything else is SC127E, with
// a fix-it that casts to the underlying type first.

enum Direction { North, East, South, West }
enum Opcode derives u8 { Nop, Halt }

fn casts(a: i64, b: u32, c: u8) {
    var d = a as Direction
// DIAG:      enum_cast.k:[[@LINE-1]]:13: error [SC127E]: casting 'i64' to 'Direction' needs its underlying type 'u32'; cast to 'u32' first
// DIAG-NEXT: fix-it:"{{.*}}enum_cast.k":{[[@LINE-2]]:13-[[@LINE-2]]:14}:"(a as u32)"
    var e = b as Direction
    var o = c as Opcode
    var p = b as Opcode
// DIAG:      enum_cast.k:[[@LINE-1]]:13: error [SC127E]: casting 'u32' to 'Opcode' needs its underlying type 'u8'; cast to 'u8' first
// DIAG-NEXT: fix-it:"{{.*}}enum_cast.k":{[[@LINE-2]]:13-[[@LINE-2]]:14}:"(b as u8)"
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
