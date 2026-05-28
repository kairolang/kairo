/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#include <array>
#include <string>

#include "controller/include/shared/file_system.hh"

#if defined(_WIN32) || defined(_WIN64)
#include <windows.h>
#define PATH_MAX MAX_PATH
#else
#include <unistd.h>

#include <climits>
#include <cstring>
#endif

__CONTROLLER_FS_BEGIN {
    std::string get_cwd() {
#if defined(_WIN32) || defined(_WIN64)
#include "controller/lib/shared/windows/__cwd.inc"
#else
#include "controller/lib/shared/unix/__cwd.inc"
#endif
        return {buffer.data()};
    }
}  // __CONTROLLER_FS_BEGIN
