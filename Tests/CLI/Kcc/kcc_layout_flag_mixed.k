// A layout-affecting clang flag in a translation unit that touches Kairo
// types is an error (c-cpp-toolchain.mdx, Compiler Flags Across the
// Boundary, 3. Layout-affecting: `-fno-rtti`, `-fshort-enums`, packing
// "are rejected in any translation unit that touches Kairo types").
// Inputs/use_shapes.cc includes shapes.k, so it is such a TU.
//
// XFAIL: *
// Ticket "[Driver] Bring clang's options into kairo (the \"clang flags
// pass\")" (private/IMPORTANT/TICKETS.TXT, 2026-10-24): the doc's error
// for a layout-affecting flag (and for a single-language flag in a mixed
// TU) is not implemented. Today kcc passes `-fno-rtti` through without a
// word and the compile succeeds. The diagnostic's code is not decided; the
// check asks for an error naming the flag. When it XPASSes, delete the
// XFAIL and pin the code and message.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: { %kcc -fno-rtti -c %S/Inputs/use_shapes.cc -o %t.d/x.o 2>&1 || true; } | %FileCheck %s
// CHECK: error{{.*}}-fno-rtti
