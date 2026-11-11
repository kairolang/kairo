/* SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
   Copyright (c) 2026 Dhruvan Kartik

   Kairo's own replacement for glibc's csu/static-reloc.c (which has no link exception).
   Written from the ABI, not from glibc's file; see Scripts/glibc-own/README for the mechanism.

   ABI requirement: a non-PIE static executable still links the start code's call to
   _dl_relocate_static_pie, which only static-PIE programs need (the real one lives in
   libc.a's static-reloc handling).  crt1.o therefore defines an empty hidden function of that
   name, and only on configurations where the start code references it (ENABLE_STATIC_PIE, from
   glibc's generated config.h, the same switch glibc's own start files use).  */

#include <config.h>

#if ENABLE_STATIC_PIE
void _dl_relocate_static_pie (void) __attribute__ ((visibility ("hidden")));

void
_dl_relocate_static_pie (void)
{
}
#endif
