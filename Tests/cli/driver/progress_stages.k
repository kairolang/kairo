// --progress=lines splits code generation into its stages: IR generation,
// optimisation and object emission each count the TUs clang finished and
// carry the CPU time spent in them (ms=), then the link is one unit with its
// wall time. A TU the object cache holds counts as done in every stage.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/inputs/incremental %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a1 --cache-dir %t.d/c --progress=lines 2>&1 | %FileCheck %s --check-prefix=FIRST
// FIRST: @progress phase=codegen done=0 total=[[C:[1-9][0-9]*]] reused=0
// FIRST-DAG: @progress phase=irgen done=0 total=[[C]] ms=0
// FIRST-DAG: @progress phase=opt done=0 total=[[C]] ms=0
// FIRST-DAG: @progress phase=emit done=0 total=[[C]] ms=0
// FIRST: @progress phase=irgen done=[[C]] total=[[C]] ms={{[0-9]+}}
// FIRST: @progress phase=opt done=[[C]] total=[[C]] ms={{[0-9]+}}
// FIRST: @progress phase=emit done=[[C]] total=[[C]] ms={{[0-9]+}}
// FIRST: @progress phase=link done=0 total=1 ms=0
// FIRST-NEXT: @progress phase=link done=1 total=1 ms={{[0-9]+}}

// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a2 --cache-dir %t.d/c --progress=lines 2>&1 | %FileCheck %s --check-prefix=SECOND
// SECOND: @progress phase=emit done=[[C:[1-9][0-9]*]] total=[[C]] ms=0
// SECOND: @progress phase=link done=1 total=1
