/* SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
   Copyright (c) 2026 Dhruvan Kartik

   Kairo's own replacement for glibc's sysdeps/generic/crtn.S (which has no notice at all).
   Written from the ABI, not from glibc's file.

   ABI requirement: riscv32, riscv64 and loongarch64 glibc programs run their constructors
   and destructors from DT_INIT_ARRAY / DT_FINI_ARRAY only (no .init / .fini prologue and
   epilogue is stitched together from crtn.o), so crtn.o is a valid, empty relocatable object:
   no code, no data, no symbols.  The linker still takes it as a link input, which is all
   the crt link line needs.  */
