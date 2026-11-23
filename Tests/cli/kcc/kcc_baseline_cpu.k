// kcc compiles for the target's default CPU unless -march or -mcpu says
// otherwise, as clang does, on the host too: kairo's host CPU default is
// not kcc's. An included Kairo file compiles for that same CPU.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, host-x86_64
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: echo 'int h() { return 2; }' > %t.d/in.cc
// RUN: cd %t.d && %kcc -### -c in.cc > %t.d/base.txt 2>&1
// RUN: %FileCheck %s --check-prefix=BASE < %t.d/base.txt
// BASE:      {{^}}clang -cc1 {{.*}}-target-cpu x86-64 -tune-cpu generic {{.*}}in.cc{{$}}
// RUN: not grep -e '-target-cpu x86-64-v' -e '-target-cpu baseline' -e 'mcpu' %t.d/base.txt

// RUN: cd %t.d && %kcc -### -c in.cc -march=x86-64-v3 > %t.d/v3.txt 2>&1
// RUN: %FileCheck %s --check-prefix=V3 < %t.d/v3.txt
// V3:        {{^}}clang -cc1 {{.*}}-target-cpu x86-64-v3 {{.*}}in.cc{{$}}
