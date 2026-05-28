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

#ifndef __UNIX_EXE_INC__
#define __UNIX_EXE_INC__

size_t            bufferSize = 256;
std::vector<char> buffer(bufferSize);

while (true) {
    ssize_t count = readlink("/proc/self/exe", buffer.data(), bufferSize);
    if (count == -1) {
        throw std::runtime_error("Failed to retrieve executable path");
    }
    if (static_cast<size_t>(count) < bufferSize) {
        return std::filesystem::path(std::string(buffer.data(), count));
    }
    bufferSize *= 2;
    buffer.resize(bufferSize);
}

#endif  // __UNIX_EXE_INC__