// Kairo's FP semantics are Kairo's alone: its own compile line carries
// -ffp-contract=off (FlagTranslator::kairo_fp_cc1), while a C or C++ input
// in the same build compiles under clang's driver with C/C++'s defaults
// (-ffp-contract=on here), never Kairo's. Under kcc too, which is kairo fed
// a clang command line. The first --print-jobs line is the Kairo one.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: echo 'int g(void) { return 1; }' > %t.d/c_in.c
// RUN: echo 'int h() { return 2; }' > %t.d/cxx_in.cc
// RUN: %kairo %s %t.d/c_in.c %t.d/cxx_in.cc --print-jobs -o %t.d/app --target=x86_64-linux-musl > %t.d/jobs.txt 2>&1
// RUN: %FileCheck %s --check-prefix=KAIRO < %t.d/jobs.txt
// KAIRO:      {{^}}clang -cc1 {{.*}}-ffp-contract=off
// KAIRO:      {{^}}clang -cc1 {{.*}}-ffp-contract=on {{.*}}c_in.c{{$}}
// KAIRO:      {{^}}clang -cc1 {{.*}}-ffp-contract=on {{.*}}cxx_in.cc{{$}}
// RUN: grep -E 'c_in\.c$|cxx_in\.cc$' %t.d/jobs.txt > %t.d/native.txt
// RUN: not grep -e '-ffp-contract=off' %t.d/native.txt

// REQUIRES: kcc
// RUN: cd %t.d && %kcc -### -c cxx_in.cc --target=x86_64-linux-musl > %t.d/kcc.txt 2>&1
// RUN: %FileCheck %s --check-prefix=KCC < %t.d/kcc.txt
// KCC:        {{^}}clang -cc1 {{.*}}-ffp-contract=on {{.*}}cxx_in.cc{{$}}
// RUN: grep -E 'cxx_in\.cc$' %t.d/kcc.txt > %t.d/kcc_native.txt
// RUN: not grep -e '-ffp-contract=off' %t.d/kcc_native.txt
