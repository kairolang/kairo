///--- The Kairo Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

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
