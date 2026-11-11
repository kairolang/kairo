/* SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
   Copyright (c) 2026 Dhruvan Kartik

   Kairo's own replacement for glibc's sysdeps/unix/sysv/linux/aarch64/__read_tp.S
   (which has no link exception).  Written from the AArch64 ABI, not from glibc's file.

   ABI requirement: libc_nonshared.a on aarch64 provides the hidden function __read_tp
   (glibc 2.17 .. 2.33), which returns the thread pointer; AAPCS64 returns it in x0, and the
   thread pointer is TPIDR_EL0.  The entry carries a BTI landing pad (hint 34, "bti c") like
   every function glibc's ENTRY macro emits, so the object is valid in a BTI-enforcing
   process.  */

	.text
	.globl __read_tp
	.hidden __read_tp
	.type __read_tp, %function
	.p2align 6
__read_tp:
	.cfi_startproc
	hint	34			/* bti c */
	mrs	x0, tpidr_el0
	ret
	.cfi_endproc
	.size __read_tp, .-__read_tp
