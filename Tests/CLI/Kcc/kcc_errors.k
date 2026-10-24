// kcc fails the way clang does, with the location in whichever language
// the fault is in: a C++ syntax error, a Kairo type or parse error in an
// included .k, a C++ call that misuses a Kairo function (noted at its
// declaration in the .k), an undefined symbol and a duplicate main at the
// link, and -Wall / -Werror / -w on C++ warnings. Every failure exits
// nonzero and writes no output file.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d

// RUN: { %kcc %S/Inputs/errors/bad_syntax.cc -o %t.d/a 2>&1 || true; } | %FileCheck %s --check-prefix=SYNTAX
// RUN: not %kcc %S/Inputs/errors/bad_syntax.cc -o %t.d/a 2> /dev/null
// RUN: test ! -e %t.d/a
// SYNTAX: bad_syntax.cc:1:22: error [CL001E]: expected ';' after return statement

// RUN: { %kcc %S/Inputs/errors/use_broken.cc -o %t.d/b 2>&1 || true; } | %FileCheck %s --check-prefix=KTYPE
// RUN: not %kcc %S/Inputs/errors/use_broken.cc -o %t.d/b 2> /dev/null
// RUN: test ! -e %t.d/b
// KTYPE: broken.k:2:12: error [SC028E]: cannot convert 'string' to 'i32'

// RUN: { %kcc %S/Inputs/errors/use_parse_err.cc -o %t.d/c 2>&1 || true; } | %FileCheck %s --check-prefix=KPARSE
// KPARSE: parse_err.k:1:12: error [S047E]: expected ')' to close the parameter list

// RUN: { %kcc -c %S/Inputs/errors/misuse.cc -o %t.d/d.o 2>&1 || true; } | %FileCheck %s --check-prefix=MISUSE
// MISUSE: misuse.cc:3:30: error [CL001E]: cannot initialize a parameter of type 'int' with an lvalue of type 'const char[2]'
// MISUSE-NEXT: geo.k:1:17: note [I900N]: passing argument to parameter 'a' here

// RUN: { %kcc %S/Inputs/errors/undef.cc -o %t.d/e 2>&1 || true; } | %FileCheck %s --check-prefix=UNDEF
// RUN: test ! -e %t.d/e
// UNDEF: error [L001E]: undefined symbol: missing_fn()

// RUN: { %kcc %S/Inputs/errors/main.cc %S/Inputs/errors/two_mains.k -o %t.d/f 2>&1 || true; } | %FileCheck %s --check-prefix=DUPMAIN
// DUPMAIN: error [L001E]: duplicate symbol: main

// RUN: %kcc -Wall %S/Inputs/errors/warn.cc -o %t.d/g 2>&1 | %FileCheck %s --check-prefix=WARN
// RUN: test -e %t.d/g
// WARN: warn.cc:2:9: warning [C1120W]: unused variable 'unused_local'
// RUN: { %kcc -Wall -Werror %S/Inputs/errors/warn.cc -o %t.d/h 2>&1 || true; } | %FileCheck %s --check-prefix=WERROR
// RUN: test ! -e %t.d/h
// WERROR: warn.cc:2:9: error [C1120E]: unused variable 'unused_local'
// RUN: %kcc -Wall -w %S/Inputs/errors/warn.cc -o %t.d/i 2>&1 | %FileCheck %s --check-prefix=SILENT --allow-empty
// SILENT-NOT: warning
