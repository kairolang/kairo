///--- The Helix Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

/// uncomment only for lsp support otherwise there will be build errors.
// #include "/Volumes/Development/Projects/Helix/helix-lang/build/release/arm64-macosx-llvm/core/include/core.hh"

#ifndef __EXEC_H__
#define __EXEC_H__

namespace helix {

inline string s2ws(const libcxx::string &str) {
    using convert_typeX = libcxx::codecvt_utf8<wchar_t>;
    libcxx::wstring_convert<convert_typeX, wchar_t> converterX;

    return converterX.from_bytes(str);
}

inline libcxx::string ws2s(const string &wstr) {
    using convert_typeX = libcxx::codecvt_utf8<wchar_t>;
    libcxx::wstring_convert<convert_typeX, wchar_t> converterX;

    return converterX.to_bytes(wstr);
}

struct ExecResult {
    string output;
    i32    return_code{};
};

#if defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64)

inline ExecResult exec(const string &wcmd) {
    SECURITY_ATTRIBUTES sa         = {sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE              hReadPipe  = nullptr;
    HANDLE              hWritePipe = nullptr;
    libcxx::string      cmd        = ws2s(wcmd);

    if (CreatePipe(&hReadPipe, &hWritePipe, &sa, 0) == 0) {
        throw libcxx::runtime_error("CreatePipe failed! Error: " +
                                    libcxx::to_string(GetLastError()));
    }

    if (SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0) == 0) {
        CloseHandle(hReadPipe);
        CloseHandle(hWritePipe);
        throw libcxx::runtime_error("SetHandleInformation failed! Error: " +
                                    libcxx::to_string(GetLastError()));
    }

    PROCESS_INFORMATION pi = {};
    STARTUPINFO         si = {};
    si.cb                  = sizeof(si);
    si.hStdOutput          = hWritePipe;
    si.hStdError           = hWritePipe;
    si.dwFlags |= STARTF_USESTDHANDLES;

    if (!CreateProcess(nullptr,
                        const_cast<wchar_t *>(cmd.c_str()),
                        nullptr,
                        nullptr,
                        TRUE,
                        CREATE_NO_WINDOW,
                        nullptr,
                        nullptr,
                        &si,
                        &pi)) {
        CloseHandle(hReadPipe);
        CloseHandle(hWritePipe);
        throw libcxx::runtime_error("CreateProcess failed! Error: " +
                                    libcxx::to_string(GetLastError()));
    }

    CloseHandle(hWritePipe);

    libcxx::string           result;
    libcxx::array<char, 128> buffer{};

    DWORD bytesRead = 0;

    libcxx::thread readerThread([&]() {
        while (true) {
            if (ReadFile(hReadPipe, buffer.data(), buffer.size(), &bytesRead, nullptr) == 0) {
                if (GetLastError() == ERROR_BROKEN_PIPE) {
                    break;
                }
                throw libcxx::runtime_error("ReadFile failed! Error: " +
                                            libcxx::to_string(GetLastError()));
            }
            result.append(buffer.data(), bytesRead);
        }
    });

    DWORD waitResult = WaitForSingleObject(pi.hProcess, 10000);  // 10 sec timeout
    if (waitResult == WAIT_TIMEOUT) {
        TerminateProcess(pi.hProcess, 1);
        readerThread.join();
        CloseHandle(hReadPipe);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        throw libcxx::runtime_error("Process timed out!");
    }

    readerThread.join();

    DWORD exitCode = 0;
    if (GetExitCodeProcess(pi.hProcess, &exitCode) == 0) {
        CloseHandle(hReadPipe);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        throw libcxx::runtime_error("GetExitCodeProcess failed! Error: " +
                                    libcxx::to_string(GetLastError()));
    }

    CloseHandle(hReadPipe);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return {.output = s2ws(result), .return_code = static_cast<int>(exitCode)};
}

#elif defined(__unix__) || defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__) ||    \
    defined(__NetBSD__) || defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__) || \
    defined(__MACH__)

inline ExecResult exec(const string &wcmd) {
    libcxx::array<char, 128> buffer{};
    libcxx::string           result;
    libcxx::string           cmd = ws2s(wcmd);

    FILE *pipe = popen(cmd.c_str(), "r");
    
    if (pipe == nullptr) {
        throw libcxx::runtime_error("popen() failed to initialize command execution.");
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

    int rc = pclose(pipe);
    return {.output = s2ws(result), .return_code = rc};
}

#endif

}  // namespace helix

#endif  // __EXEC_H__