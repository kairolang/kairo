/* --- The Kairo Project ------------------------------- Lib/std/write.h --- *
 *
 *   write(2) for std/io.k. Stage 1 has no eval if yet, so an ffi import
 *   cannot be chosen per target; the C preprocessor chooses here instead.
 *   On Windows write comes from the UCRT's <io.h> (via oldnames.lib, which
 *   every windows-msvc sysroot links) and takes an unsigned int count;
 *   io.k's caller casts to u32 for that reason.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 *
 * ------------------------------------------------------------------------ */

#pragma once

#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif
