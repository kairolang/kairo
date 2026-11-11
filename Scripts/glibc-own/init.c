/* SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
   Copyright (c) 2026 Dhruvan Kartik

   Kairo's own replacement for glibc's csu/init.c (which has no link exception).
   Written from the ABI, not from glibc's file; see Scripts/glibc-own/README for the mechanism.

   ABI requirement: crt1.o and Scrt1.o of a glibc program must define the global object
   _IO_stdin_used (4 bytes, int, in .rodata, default visibility).  glibc's libio looks
   for the symbol in the executable to tell a program built against the current libio from one
   built against the pre-2.1 libio; nothing reads the value, which stays 0x20001 (the historical
   libio version number) so that the object is the same as glibc's.  */

const int _IO_stdin_used = 0x20001;
