// `kcc --target=avr -mmcu=<mcu> -c t.c` printed clang's "no target
// microcontroller specified, please pass -mmcu" though the object was
// right: the backend's target probe ran clang's driver without the
// --cxx-flags -mmcu. It now carries it, so nothing warns.

// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: echo 'int f(int x) { return x + 1; }' > %t.d/t.c
// RUN: %kcc --target=avr -mmcu=atmega328p -ffreestanding -nostdlib -c %t.d/t.c -o %t.d/t.o 2>&1 | %FileCheck %s --allow-empty
// RUN: test -s %t.d/t.o
// CHECK-NOT: no target microcontroller
