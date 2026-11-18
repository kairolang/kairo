// Help text for the flags whose description was corrected to say what the flag
// does. Each pattern is one line of --help (descriptions are not wrapped).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --help | %FileCheck %s
// CHECK-DAG: --mcpu <value>{{ +}}target CPU {{.*}}wins over --march
// CHECK-DAG: -g{{ +}}emit debug information: DWARF, or CodeView on MSVC targets
// CHECK-DAG: --dwarf-version <2-5>{{ +}}DWARF version to emit: 2|3|4|5 (default: 5); needs -g
// CHECK-DAG: --debug-macros{{ +}}embed macro definitions in DWARF debug info (needs -g)
// CHECK-DAG: --embed-source{{ +}}embed source text in DWARF debug sections (needs -g and DWARF 5)
// CHECK-DAG: --pic-level <0-2>{{ +}}PIC level on any target
// CHECK-DAG: -f[no-]pie{{ +}}position-independent executable (a link-time choice; code generation is unchanged)
// CHECK-DAG: -f[no-]vectorize{{ +}}auto-vectorisation (loop + SLP); on at every level above -O0
// CHECK-DAG: --save-temps{{ +}}keep the object files, under <out>.kobj/ (only without --cache-dir)
// CHECK-DAG: --m32{{ +}}force 32-bit code generation: --target becomes its 32-bit variant
// CHECK-DAG: --remap-path-prefix <value>...{{ +}}old=new path prefix remapping for debug info, coverage mappings and __FILE__-style macros
// CHECK-DAG: --cxx-std <value>{{ +}}C++ standard for interop: c++20|c++23|c++26
// CHECK-DAG: --profile <value>{{ +}}build profile: debug (-O0 -g), release (-O2), min-size (-Os)
// CHECK-DAG: --unwind-tables <value>{{ +}}unwind table emission: none|sync|async (default: per target; async on x86_64)
