/* A C header, imported `ffi "c"`: c_add must keep C linkage to link against
   c_add.c, and c_mac is C code that keeps C's FP contraction. */
#ifndef C_ADD_H
#define C_ADD_H
int c_add(int a, int b);
static inline double c_mac(double a, double b, double c) { return a * b + c; }
#endif
