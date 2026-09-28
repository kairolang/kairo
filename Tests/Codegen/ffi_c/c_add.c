/* Corpus for ffi_c/main.k: compiled as C, so `c_add` is the unmangled
 * symbol the Kairo side must reach. */
#include "c_add.h"

int c_add(int a, int b) { return a + b; }
