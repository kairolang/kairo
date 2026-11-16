// An extension's `op as` follows the extension-visibility rule: this file
// imports ext.k, so `Feet` converts to `M` here, written and unwritten.

import self::types::*
import self::ext::*

fn main() -> i32 {
    var f = Feet{v: 2}
    return take(f) + (f as M).v - 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
