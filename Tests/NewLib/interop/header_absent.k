// A file that imports no C++ header still compiles against the whole
// library: every interop extension is guarded by `__builtin_is_declared` on
// the C++ type it names, so none of them is seen, no libc++ header is
// parsed for them, and nothing of theirs reaches the object. The same
// program with the headers imported (Inputs/header_present.k) does define
// them, which shows the symbol names searched for are the right ones. The
// object is searched for the interop names only: the runtime's demangler
// has C++ string views of its own.

import std::io

fn main() -> i32 {
    var s = f"no {1} header"
    var v = Vector<i32>()
    v.push(3)
    var m = HashMap<i32, i32>()
    m[1] = 2
    var t = HashSet<i32>()
    t.insert(4)
    io::println(f"{s} {v.size()} {m.size()} {t.size()}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// REQUIRES: llvm-nm
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: %nm %t.exe | %FileCheck %s --check-prefix=ABSENT
// RUN: %kairo_new %s --print-ir | %FileCheck %s --check-prefix=IR
// RUN: %kairo_new %S/Inputs/header_present.k -o %t.p.exe --cache-dir %t.pd
// RUN: %nm %t.p.exe | %FileCheck %s --check-prefix=PRESENT
// OUT: no 1 header 1 1 1
// ABSENT-NOT: cxx_containers
// ABSENT-NOT: cxx_string
// ABSENT-NOT: into_cxx
// IR-NOT: into_cxx
// IR-NOT: std::string_view
// IR-NOT: std::vector
// PRESENT: cxx_containers{{.*}}into_cxx
