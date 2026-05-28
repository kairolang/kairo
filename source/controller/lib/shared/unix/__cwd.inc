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