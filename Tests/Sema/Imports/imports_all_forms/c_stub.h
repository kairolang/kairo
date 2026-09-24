/* Corpus for main.k form 9: a local stand-in for <stdio.h>. Local on purpose:
 * the phase-A clang invocation carries no host system include paths, and the
 * point of form 9 is the import shape, not libc. `printf` keeps its real
 * C-variadic signature so the step exercises `...` too. */
#ifndef KAIRO_TEST_C_STUB_H
#define KAIRO_TEST_C_STUB_H

int printf(const char* fmt, ...);

#endif
