// The help text of the linker flags says what they do: --print-ld-args names the
// real linkers, --freestanding lists everything it implies, and so on. Only the
// first words of each description are pinned so a re-wrap does not break this.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --help | %FileCheck %s --check-prefix=H
// H-DAG: print the exact ld.lld/ld64.lld/lld-link/wasm-ld
// H-DAG: partial RELRO
// H-DAG: do not import the std root
// H-DAG: freestanding: implies
// H-DAG: Mach-O dead stripping
// H-DAG: entry symbol; only applies
// H-DAG: produce a DLL (alias of --shared on every target)
