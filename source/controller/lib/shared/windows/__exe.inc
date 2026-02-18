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
