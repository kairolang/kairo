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

#ifndef __MACH_O_EXE_INC__
#define __MACH_O_EXE_INC__

uint32_t          bufferSize = 256;
std::vector<char> buffer(bufferSize);

while (true) {
    if (_NSGetExecutablePath(buffer.data(), &bufferSize) == 0) {
        return std::filesystem::path(buffer.data());
    }
    
    buffer.resize(bufferSize);  // _NSGetExecutablePath updates bufferSize if it was too small
}

#endif  // __MACH_O_EXE_INC__