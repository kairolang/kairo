// An exported function's by-value parameter is passed as written, whatever
// its body does with it: the definitions of Pp::Words are compiled in one
// run, and this file calls them through a declaration-only Pp::Words (no
// bodies) in another. Both spell `measure(Box)`, so the objects link and
// the calls run. 5 + 10 + 6 = 21.

import Pp::Boxes::Box
import Pp::Words::{
    grow,
    measure,
    twice,
}

fn main() -> i32 {
    var b = Box(5)
    var n = measure(b) + twice(b) + grow(b)
    if b.n != 5 { return 1 }
    return n
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %S/inputs/common/Pp/Boxes.k -I %S/inputs/common -c --emit-scope=inputs -o %t.d/boxes.o --cache-dir %t.d/c0
// RUN: %kairo %S/inputs/def/Pp/Words.k -I %S/inputs/def -I %S/inputs/common -c --emit-scope=inputs -w -o %t.d/words.o --cache-dir %t.d/c1
// RUN: %kairo %s -I %S/inputs/decl -I %S/inputs/common -c --emit-scope=inputs -o %t.d/main.o --cache-dir %t.d/c2
// RUN: %kairo %t.d/main.o %t.d/words.o %t.d/boxes.o --kairo-lib -o %t.d/main.exe
// RUN: %t.d/main.exe; test $? -eq 21
// The definition still says to write `const`: that is how an exported
// parameter is passed by reference.
// RUN: { %kairo %S/inputs/def/Pp/Words.k -I %S/inputs/def -I %S/inputs/common --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=WARN --implicit-check-not="warning ["
// WARN: Words.k:9:16: warning [SC224W]: parameter 'b' is never mutated; declare it 'const'
// WARN: Words.k:11:14: warning [SC224W]: parameter 'b' is never mutated; declare it 'const'
