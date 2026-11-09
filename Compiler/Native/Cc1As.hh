/* --- The Kairo Project ----------------------- Compiler/Native/Cc1As.hh --- */
/*
 *   clang's integrated assembler entry point, `clang -cc1as`. It lives in
 *   clang/tools/driver/cc1as_main.cpp, which is not part of any clang
 *   library, so build.py compiles that file from the fork into every Kairo
 *   binary. ClangJobs runs a driver's -cc1as job through it
 *   in-process, as clang's own driver does, so .s / .S inputs build with no
 *   external assembler.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 */
#pragma once

#include <llvm/ADT/ArrayRef.h>

/// \p Argv: the job's arguments AFTER "-cc1as" (clang's driver passes
/// ArgV.slice(2)). \p MainAddr is unused by cc1as_main.
int cc1as_main(llvm::ArrayRef<const char *> Argv, const char *Argv0, void *MainAddr);
