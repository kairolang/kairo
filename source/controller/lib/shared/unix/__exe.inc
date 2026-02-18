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