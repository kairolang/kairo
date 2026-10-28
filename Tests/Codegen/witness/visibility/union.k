// witness/visibility/union.k -- `both<Metric>` binds two rows found through
// two extension files, Scalable from ea.k and Named from eb.k. u1.k imports
// them in one order and u2.k in the other (and sits deeper in the DAG, so it
// is checked second). An instance's rows are the union over every TU that
// checked it, in first-found order (MONO.md D7), so both TUs' C++ carry the
// same two witness specializations in the same order, whatever each
// imported first. (A pin, not a regression test: before D7 the first TU's
// list was kept, and here it was already the same.)
//
// Its extensions break the not-yet-diagnosed orphan rule on purpose; see
// late.k.
import c1
import c2
import c3
import u1
import u2
fn main() -> i32 { return u1::use_1() + u2::use_2() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}u2.k
// IR:       template<> struct Scalable_witness< ::{{([A-Za-z_]+::)*}}metric::Metric> {
// IR:       template<> struct Named_witness< ::{{([A-Za-z_]+::)*}}metric::Metric> {
// IR-LABEL: CODEGEN C++: {{.*}}u1.k
// IR:       template<> struct Scalable_witness< ::{{([A-Za-z_]+::)*}}metric::Metric> {
// IR:       template<> struct Named_witness< ::{{([A-Za-z_]+::)*}}metric::Metric> {
// IR-LABEL: CODEGEN C++: {{.*}}union.k

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// u1: 1 * 10 + (1 + 7); u2: 2 * 10 + (2 + 7) + 1.
// RUN: %t.exe; test $? -eq 48
