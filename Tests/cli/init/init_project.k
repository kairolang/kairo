// --init <dir> copies the installed project template into <dir>: the program
// in source/, the library in include/, the two builds and the notes. The
// program it creates builds with `-I include` and runs, printing the three
// expressions the example evaluates.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t
// RUN: %kairo --init %t/demo | %FileCheck %s --check-prefix=CREATED
// CREATED: created {{.*}}demo/source/main.k
// CREATED-NEXT: created {{.*}}demo/include/module.k
// CREATED-NEXT: created {{.*}}demo/include/calc.k
// CREATED-NEXT: created {{.*}}demo/GETTING_STARTED.txt
// CREATED-NEXT: created {{.*}}demo/.gitignore
// CREATED-NEXT: created {{.*}}demo/Makefile
// CREATED-NEXT: created {{.*}}demo/build.cmd
// CREATED-EMPTY:
// CREATED-NEXT: next steps:
// RUN: cd %t/demo && find . -type f | sort | %FileCheck %s --check-prefix=FILES
// FILES: ./.gitignore
// FILES-NEXT: ./GETTING_STARTED.txt
// FILES-NEXT: ./Makefile
// FILES-NEXT: ./build.cmd
// FILES-NEXT: ./include/calc.k
// FILES-NEXT: ./include/module.k
// FILES-NEXT: ./source/main.k
// FILES-NOT: {{.}}
// RUN: %FileCheck %s --check-prefix=MOD --input-file %t/demo/include/module.k
// MOD: {{^}}module demo{{$}}
// MOD: pub import self::calc
// RUN: %FileCheck %s --check-prefix=MK --input-file %t/demo/Makefile
// MK: NAME = demo
// RUN: %FileCheck %s --check-prefix=IGN --input-file %t/demo/.gitignore
// IGN: {{^}}build/{{$}}
// RUN: rm -f %t.exe
// RUN: %kairo %t/demo/source/main.k -I %t/demo/include -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 3 4 + 2 *  =>  14
// OUT-NEXT: 1 2 3  =>  error: numbers are left over: an operator is missing
// OUT-NEXT: 2 x +  =>  error: 'x' is not a number or an operator
// RUN: rm -f %t.exe
