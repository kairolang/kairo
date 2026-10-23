// C/C++ inputs go through clang's own driver (Interop/Clang/ClangJobs.k),
// run in-process, on the build's target and header roots. They follow the
// run's action like Kairo inputs: -c, -S, --emit=llvm-ir/llvm-bc,
// --preprocess, --syntax-only. Under that driver a C/C++ input gets clang's
// own defaults; a kairo flag changes them only when it is given
// (FlagTranslator::to_driver).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// -S / --emit=llvm-ir / --emit=llvm-bc write <stem>.s .ll .bc.
// RUN: %kairo %S/Inputs/native_ir.c -S --cache-dir %t.d/asm
// RUN: %FileCheck %s --check-prefix=ASM --input-file=%t.d/asm/native_ir.s
// ASM: main:
// RUN: %kairo %S/Inputs/native_ir.c --emit=llvm-ir,llvm-bc --cache-dir %t.d/ir
// RUN: %FileCheck %s --check-prefix=IR --input-file=%t.d/ir/native_ir.ll
// IR: define {{.*}}i32 @main()
// RUN: test -s %t.d/ir/native_ir.bc

// IR is an input like any other: each compiles to an object and links.
// RUN: %kairo %t.d/ir/native_ir.ll -o %t.d/from_ll --cache-dir %t.d/oll
// RUN: %t.d/from_ll; test $? -eq 9
// RUN: %kairo %t.d/ir/native_ir.bc -o %t.d/from_bc --cache-dir %t.d/obc
// RUN: %t.d/from_bc; test $? -eq 9

// --preprocess is clang's -E: to stdout, or to -o.
// RUN: %kairo --preprocess --cxx-define=FROM_CXX_DEFINE --cxx-flags=-DFROM_CXX_FLAGS %S/Inputs/native_flags.cc | %FileCheck %s --check-prefix=PP
// PP: int flags_ok()

// --syntax-only and --type-check-only check a C/C++ input and write nothing.
// RUN: %kairo --syntax-only %S/Inputs/native_add.cc
// RUN: %kairo --type-check-only %S/Inputs/native_add.cc
// RUN: { %kairo --syntax-only %S/Inputs/native_bad.cc 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: native_bad.cc:1:{{[0-9]+}}: error [CL001E]: use of undeclared identifier 'undeclared_name'
// RUN: not %kairo --syntax-only %S/Inputs/native_bad.cc > /dev/null 2>&1

// Flags reach the input: --cxx-define is clang's -D, --cxx-flags are
// clang words passed last.
// RUN: %kairo -c --cxx-define=FROM_CXX_DEFINE --cxx-flags=-DFROM_CXX_FLAGS %S/Inputs/native_flags.cc --cache-dir %t.d/flags
// RUN: test -s %t.d/flags/native_flags.o
// RUN: not %kairo -c --cxx-define=FROM_CXX_DEFINE %S/Inputs/native_flags.cc --cache-dir %t.d/flags > /dev/null 2>&1

// Clang's defaults unless a kairo flag says otherwise: C++ exceptions are on
// for a .cc (kairo's own code compiles without them), -fno-exceptions turns
// them off; C gets clang's default standard unless --c-std names one.
// RUN: %kairo -c %S/Inputs/native_throw.cc --cache-dir %t.d/exc
// RUN: { %kairo -c -fno-exceptions %S/Inputs/native_throw.cc --cache-dir %t.d/exc 2>&1 || true; } | %FileCheck %s --check-prefix=NOEXC
// NOEXC: error [CL001E]: cannot use 'throw' with exceptions disabled
// RUN: %kairo -c --c-std=c23 %S/Inputs/native_c23.c --cache-dir %t.d/c23
// RUN: not %kairo -c --c-std=c11 %S/Inputs/native_c23.c --cache-dir %t.d/c11 > /dev/null 2>&1

// Objective-C, Objective-C++ and preprocessed inputs compile through the
// same driver.
// RUN: %kairo -c %S/Inputs/native_objc.m %S/Inputs/native_objcxx.mm %S/Inputs/native_pp.i --cache-dir %t.d/langs
// RUN: test -s %t.d/langs/native_objc.o
// RUN: test -s %t.d/langs/native_objcxx.o
// RUN: test -s %t.d/langs/native_pp.o

// A header is precompiled, as clang does with one: <file>.pch, never linked.
// RUN: %kairo -c %S/Inputs/native_header.h --cache-dir %t.d/pch
// RUN: test -s %t.d/pch/native_header.h.pch
// RUN: %kairo -x c++-header %S/Inputs/native_header.h -o %t.d/explicit.pch
// RUN: test -s %t.d/explicit.pch

// Two inputs with one stem would write one file: an error, nothing compiled.
// RUN: { %kairo -c %S/Inputs/native_dup.c %S/Inputs/dup/native_dup.c --cache-dir %t.d/dup 2>&1 || true; } | %FileCheck %s --check-prefix=DUP
// DUP: error [U001E]: {{.*}}native_dup.c and {{.*}}dup/native_dup.c both write 'native_dup' outputs
// RUN: not test -e %t.d/dup/native_dup.o

// -o names the build's one output; two C/C++ inputs have no single name.
// RUN: { %kairo -c %S/Inputs/native_add.cc %S/Inputs/native_main.c -o %t.d/one.o 2>&1 || true; } | %FileCheck %s --check-prefix=ONEO
// ONEO: fatal [I004F]: -o {{.*}}one.o names one output, but this build emits 2

// --print-clang-args shows the line clang's driver plans for each C/C++
// input after kairo's own: the build's triple, and clang's C++ defaults.
// RUN: %kairo %S/Inputs/native_throw.cc --print-clang-args | %FileCheck %s --check-prefix=PCA
// PCA:      clang -cc1 -triple {{[^ ]+}} {{.*}}-x c++ '<injected>'
// PCA-NEXT: clang -cc1 {{.*}}-fcxx-exceptions -fexceptions {{.*}}-x c++ {{.*}}native_throw.cc
// The input's line is the last one; with -fno-exceptions it has no
// -fcxx-exceptions at all.
// RUN: %kairo %S/Inputs/native_throw.cc --print-clang-args -fno-exceptions | tail -n 1 > %t.d/pcano.txt
// RUN: grep -q 'native_throw.cc' %t.d/pcano.txt
// RUN: not grep -q -- '-fcxx-exceptions' %t.d/pcano.txt

// Driver-produced -mllvm words survive: -masm=intel is one.
// RUN: %kairo %S/Inputs/native_ir.c -S --cxx-flags=-masm=intel --cache-dir %t.d/intel
// RUN: %FileCheck %s --check-prefix=INTEL --input-file=%t.d/intel/native_ir.s
// INTEL: .intel_syntax

// --Werror makes a C/C++ input's warnings errors.
// RUN: %kairo -c --Wall %S/Inputs/native_warn.c --cache-dir %t.d/warn
// RUN: not %kairo -c --Wall --Werror %S/Inputs/native_warn.c --cache-dir %t.d/werror > /dev/null 2>&1

// One input's errors do not fail the next one: each compile has its own
// diagnostics. Exactly one error, and the good input's object is written.
// RUN: { %kairo -c %S/Inputs/native_bad.cc %S/Inputs/native_add.cc --cache-dir %t.d/two 2>&1 || true; } | grep -c 'error \[CL' | grep -qx 1
// RUN: test -s %t.d/two/native_add.o

// Runs that write no files have no output names to collide.
// RUN: %kairo --syntax-only %S/Inputs/native_dup.c %S/Inputs/dup/native_dup.c

// Nothing to preprocess in a .i: skipped with a warning, the run succeeds.
// RUN: %kairo --preprocess %S/Inputs/native_pp.i 2>&1 | %FileCheck %s --check-prefix=PPSKIP
// PPSKIP: warning [U001W]: {{.*}}native_pp.i: nothing to do for this input under --preprocess

// -o is checked before anything is written: an existing file survives a
// batch that turns out to have two outputs.
// RUN: echo keep > %t.d/keep.o
// RUN: not %kairo -c %S/Inputs/native_add.cc %S/Inputs/native_header.h -o %t.d/keep.o > /dev/null 2>&1
// RUN: grep -qx keep %t.d/keep.o

// A header beside a linking build: its .pch is kept (working directory),
// not left in the run's temporary object directory.
// RUN: rm -rf %t.d/cwd && mkdir -p %t.d/cwd
// RUN: cd %t.d/cwd && %kairo %S/Inputs/native_main.c %S/Inputs/native_add.cc %S/Inputs/native_header.h -o app
// RUN: test -s %t.d/cwd/native_header.h.pch
// RUN: test -x %t.d/cwd/app
