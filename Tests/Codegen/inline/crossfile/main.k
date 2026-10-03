import lib::*

fn main() -> i32 {
    var g = Gate { open: true }
    var r: i32 = 0
    if g.is_open() { r = twice(21) }
    return r                                   // 42
}

// --- lit wiring -----------------------------------------------------------
// `inline` puts the body in the interface: an importer compiles lib's inline
// method and free function itself rather than calling into lib.o.
//
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 42

// The consumer defines both inline functions itself: weak definitions, not
// undefined references. U here would mean it still calls into lib's object.
// RUN: nm %t.d/main.o | grep -E ' W .*is_open'
// RUN: nm %t.d/main.o | grep -E ' W .*twice'

// At -O2 they inline away.
// RUN: %kairo %s -c -O2 --cache-dir %t.o2
// RUN: objdump -dr --no-show-raw-insn %t.o2/main.o | awk '/<main>:/,/^$/' | { ! grep -q call; }

// The header carries the inline bodies too, after the class definition and
// outside it, so the class text is unchanged.
// RUN: rm -rf %t.h
// RUN: %kairo %s --type-check-only --emit-headers %t.h
// RUN: cat $(find %t.h -name lib.hh) | %FileCheck %s --check-prefix=HDR
// HDR: class Gate {
// HDR: bool is_open();
// HDR-NEXT: };
// HDR: inline bool Gate::is_open() {
// HDR: inline signed int twice(signed int x) {
