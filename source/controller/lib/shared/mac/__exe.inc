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