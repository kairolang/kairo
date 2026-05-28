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

#ifndef __WIN32_EXE_INC__
#define __WIN32_EXE_INC__

DWORD             bufferSize = 256;
std::vector<char> buffer(bufferSize);

while (true) {
    DWORD result = GetModuleFileNameA(NULL, buffer.data(), bufferSize);
    if (result == 0) {
        throw std::runtime_error("Failed to retrieve executable path");
    }
    if (result < bufferSize) {
        return std::filesystem::path(buffer.data());
    }
    bufferSize *= 2;
    buffer.resize(bufferSize);
}

#endif  // __WIN32_EXE_INC__
