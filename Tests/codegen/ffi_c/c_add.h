/* Corpus for ffi_c/main.k. A plain C header: deliberately NO
 * `#ifdef __cplusplus extern "C"` guard. Imported `ffi "c"`, the compiler
 * must supply the C linkage itself, or the call is mangled and never links
 * against c_add.c's object. */
#ifndef KAIRO_TEST_C_ADD_H
#define KAIRO_TEST_C_ADD_H

int c_add(int a, int b);

#endif
