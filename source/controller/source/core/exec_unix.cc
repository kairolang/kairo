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

#include "controller/include/tooling/tooling.hh"

#if defined(__unix__) || defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__) ||      \
    defined(__NetBSD__) || defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__) || \
    defined(__MACH__)

#include <unistd.h>

#include <array>
#include <cstdio>
#include <stdexcept>
#include <string>

CXIRCompiler::ExecResult CXIRCompiler::exec(const std::string &cmd) {
    std::array<char, 128> buffer;
    std::string           result;

    FILE *pipe = popen(cmd.c_str(), "r");
    if (!pipe) {
        throw std::runtime_error("popen() failed to initialize command execution.");
    }

    try {
        while (feof(pipe) == 0) {
            if (fgets(buffer.data(), buffer.size(), pipe) != nullptr) {
                result += buffer.data();
            }
        }
    } catch (...) {
        pclose(pipe);
        throw;
    }

    // Close the pipe and check the return code
    int rc = pclose(pipe);
    if (rc == 0) {
        return {result, 0};
    }

    return {result, rc};
}

#endif
