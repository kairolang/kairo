// --progress (Compiler/Spec/Driver.md#progress): `lines` writes one
// `@progress` event per finished unit on stderr, for a program (build.py) to
// read; `never`, and `auto` on a pipe, write none. The counts are the
// graph's, so they are matched by capture, not by value: each phase opens at
// done=0 and ends with done == total.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/incremental %t.d/s

// First build: every TU compiles, nothing is reused.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a1 --cache-dir %t.d/c --progress=lines 2>&1 | %FileCheck %s --check-prefix=FIRST
// FIRST: @progress phase=parse done=0 total=[[P:[1-9][0-9]*]]
// FIRST: @progress phase=parse done=[[P]] total=[[P]] file={{.+}}.k
// FIRST: @progress phase=sema done=0 total=[[S:[1-9][0-9]*]]
// FIRST: @progress phase=sema done=[[S]] total=[[S]] file={{.+}}.k
// FIRST: @progress phase=codegen done=0 total=[[C:[1-9][0-9]*]] reused=0
// FIRST: @progress phase=codegen done=[[C]] total=[[C]] reused=0 file={{.+}}.k

// Second build: the object cache holds every TU, which counts as done and as
// reused, and no codegen event names a file.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a2 --cache-dir %t.d/c --progress=lines 2>&1 | %FileCheck %s --check-prefix=SECOND
// SECOND: @progress phase=codegen done=0 total=[[C:[1-9][0-9]*]] reused=0
// SECOND-NEXT: @progress phase=codegen done=[[C]] total=[[C]] reused=[[C]]{{$}}

// No progress text when it is off, or when stderr is a pipe.
// RUN: rm -rf %t.d/c2 && cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a3 --cache-dir %t.d/c2 --progress=never 2>&1 | %FileCheck %s --check-prefix=NONE --implicit-check-not=@progress --implicit-check-not=sema --allow-empty
// RUN: rm -rf %t.d/c3 && cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a4 --cache-dir %t.d/c3 2>&1 | %FileCheck %s --check-prefix=NONE --implicit-check-not=@progress --implicit-check-not=sema --allow-empty
// RUN: rm -rf %t.d/c4 && cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a5 --cache-dir %t.d/c4 --progress=auto 2>&1 | %FileCheck %s --check-prefix=NONE --implicit-check-not=@progress --implicit-check-not=sema --allow-empty
// NONE: {{.*}}

// An unknown value is an error naming the choices.
// RUN: { %kairo %t.d/s/main.k --type-check-only --progress=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=VALUE
// VALUE: invalid --progress value 'bogus'; expected one of: auto, always, never, lines
