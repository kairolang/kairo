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

#ifndef __UNIX_CWD_INC__
#define __UNIX_CWD_INC__

const char *cwd_env = std::getenv("PWD");
if (cwd_env != nullptr) {
    return {cwd_env};
}

// fallback to using sys calls
std::array<char, PATH_MAX> buffer{};

if (getcwd(buffer.data(), buffer.size()) == nullptr) {
    throw std::runtime_error(
        std::string("failed to get cwd, set the envrionment variable 'PWD': ") +
        strerror(errno));
}

#endif  // __UNIX_CWD_INC__