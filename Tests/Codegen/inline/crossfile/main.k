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
// REQUIRES: clang, llvm-nm, llvm-objdump
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

// The consumer defines both inline functions itself: weak definitions, not
// undefined references. U here would mean it still calls into lib's object.
// ELF nm marks them W; Mach-O nm only says so under -m ("weak external");
// COFF has no weak definitions, so they are COMDATs: each in its own
// .text$<symbol> section.
// RUN: %nm %t.d/main.o | grep -E ' W .*is_open' || %nm -m %t.d/main.o | grep -E 'weak external .*is_open' || %objdump -h %t.d/main.o | grep -E 'text\$.*is_open'
// RUN: %nm %t.d/main.o | grep -E ' W .*twice' || %nm -m %t.d/main.o | grep -E 'weak external .*twice' || %objdump -h %t.d/main.o | grep -E 'text\$.*twice'

// At -O2 they inline away. MinGW's main opens with `call __main` (CRT
// static init); the sed drops that call and its relocation line.
// RUN: %kairo %s -c -O2 --cache-dir %t.o2
// RUN: %objdump --show-all-symbols -dr --no-show-raw-insn %t.o2/main.o | awk '/<_?main>:/,/^$/' | sed '/call/{N;/__main/d;}' | { ! grep -qE 'call|[[:space:]]bl[[:space:]]|[[:space:]]jalr[[:space:]]'; }

// The header carries the inline bodies too, after the class definition and
// outside it, so the class text is unchanged.
// RUN: rm -rf %t.h
// RUN: %kairo %s --type-check-only --emit-headers %t.h
// RUN: cat $(find %t.h -name lib.hh) | %FileCheck %s --check-prefix=HDR
// HDR: class Gate {
// HDR: bool is_open() noexcept;
// HDR-NEXT: };
// HDR: inline bool Gate::is_open() noexcept {
// HDR: inline signed int twice(signed int x) noexcept {
