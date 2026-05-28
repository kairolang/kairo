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

#ifndef __WIN32_CWD_INC__
#define __WIN32_CWD_INC__

// Use _dupenv_s for safer environment variable access
char* cwd_env = nullptr;
size_t len = 0;
errno_t err = _dupenv_s(&cwd_env, &len, "PWD");

if (err == 0 && cwd_env != nullptr) {
    std::string cwd_str{cwd_env};
    free(cwd_env);  // Free the memory allocated by _dupenv_s
    return cwd_str;
}

// Fallback to using system calls
std::array<char, MAX_PATH> buffer{};
DWORD length = GetCurrentDirectory(static_cast<DWORD>(buffer.size()), buffer.data());
if (length == 0) {
    throw std::runtime_error("Failed to get cwd, set the environment variable 'PWD': " +
                             std::to_string(GetLastError()));
}

#endif  // __WIN32_CWD_INC__
