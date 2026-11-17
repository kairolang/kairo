// A vector is two words, word-aligned, and trivially relocatable for every
// element type, and the same size as its slice; a Drain is four words.
// Checked at compile time on 64- and 32-bit targets (armv7 is the 32-bit one:
// i686 stops earlier, on the known `u64?` size assertion): each check is an eval
// constant that divides by zero when the layout is wrong, so a layout change
// fails the build. (A `compile_error!` under `eval if` cannot be used for
// this: the macro is expanded whichever way the branch goes.)

import self::Inputs::elems::*

eval W: usize = sizeof usize

macro layout!(NAME, E) {
    eval NAME: usize = 1 / (if sizeof [E] == 2 * W && alignof [E] == W && __builtin_is_trivially_relocatable<[E]>() && sizeof Drain<E> == 4 * W && sizeof [E;] == sizeof [E] => 1 else => 0)
}

layout!(L_I32, i32)
layout!(L_U8, u8)
layout!(L_P3, P3)
layout!(L_B64, B64)
layout!(L_A128, A128)
layout!(L_STRING, string)
layout!(L_VEC, [string])
layout!(L_TRACKED, Tracked)
layout!(L_RTRACKED, RTracked)

fn main() -> i32 {
    var ok = L_I32 + L_U8 + L_P3 + L_B64 + L_A128 + L_STRING + L_VEC + L_TRACKED + L_RTRACKED
    return (ok - 9) as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s --emit=obj --target=x86_64-linux-gnu -o %t.x86_64.o --cache-dir %t.d/x86_64
// RUN: %kairo_new %s --emit=obj --target=aarch64-linux-gnu -o %t.aarch64.o --cache-dir %t.d/aarch64
// RUN: %kairo_new %s --emit=obj --target=armv7-linux-gnueabihf -o %t.armv7.o --cache-dir %t.d/armv7
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
