// --init writes nothing when any file it would create is already there: it
// names the first one, exits nonzero, and the existing file and the rest of
// the directory are left as they were. A path that is a file is refused too.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t/demo/source
// RUN: echo 'fn main() { }' > %t/demo/source/main.k
// RUN: { not %kairo --init %t/demo 2>&1; } | %FileCheck %s
// CHECK: error [U001E]: --init: '{{.*}}demo/source/main.k' already exists; nothing was written
// RUN: test ! -e %t/demo/include
// RUN: test ! -e %t/demo/Makefile
// RUN: test ! -e %t/demo/.gitignore
// RUN: %FileCheck %s --check-prefix=KEPT --input-file %t/demo/source/main.k
// KEPT: {{^}}fn main() { }{{$}}
// RUN: touch %t/afile
// RUN: { not %kairo --init %t/afile 2>&1; } | %FileCheck %s --check-prefix=FILE
// FILE: error [U001E]: --init: '{{.*}}afile' exists and is not a directory
// RUN: { not %kairo --init %t/a %t/b 2>&1; } | %FileCheck %s --check-prefix=TWO
// TWO: error [U001E]: --init takes one directory, the project to create
// RUN: test ! -e %t/a
