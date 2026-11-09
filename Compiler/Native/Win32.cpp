/* --- The Kairo Project ---------------------- Compiler/Native/Win32.cpp --- */
/*
 *   The one place the compiler includes <windows.h>: see Win32.hh.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 */
#include "Win32.hh"

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <string>

namespace kairo::win32 {

static std::wstring widen(const char *s, size_t len) {
    if (len == 0) { return {}; }
    int n = MultiByteToWideChar(CP_UTF8, 0, s, static_cast<int>(len), nullptr, 0);
    if (n <= 0) { return {}; }
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, static_cast<int>(len), w.data(), n);
    return w;
}

bool map_readonly(const char *path, size_t len, unsigned char **data, size_t *size) {
    *data = nullptr;
    *size = 0;
    // UTF-8 -> UTF-16 for the W API; the narrow CreateFileA would read the bytes
    // in the ANSI code page.
    std::wstring w = widen(path, len);
    HANDLE file = CreateFileW(w.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) { return false; }
    LARGE_INTEGER fsize;
    if (!GetFileSizeEx(file, &fsize) || fsize.QuadPart < 0
        || static_cast<unsigned long long>(fsize.QuadPart) > static_cast<unsigned long long>(SIZE_MAX)) {
        CloseHandle(file);
        return false;
    }
    if (fsize.QuadPart == 0) {   // nothing to map: a static empty buffer, not a view
        static unsigned char empty[1] = {0};
        CloseHandle(file);
        *data = empty;
        return true;
    }
    HANDLE map = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (map == nullptr) {
        CloseHandle(file);
        return false;
    }
    void *view = MapViewOfFile(map, FILE_MAP_READ, 0, 0, 0);
    CloseHandle(map);
    CloseHandle(file);
    if (view == nullptr) { return false; }
    *data = static_cast<unsigned char *>(view);
    *size = static_cast<size_t>(fsize.QuadPart);
    return true;
}

void unmap(void *data) {
    if (data) { UnmapViewOfFile(data); }
}

size_t exe_path_utf8(char *buf, size_t cap) {
    wchar_t w[32768];
    DWORD len = GetModuleFileNameW(nullptr, w, 32768);
    if (len == 0 || len == 32768) { return 0; }
    int n = WideCharToMultiByte(CP_UTF8, 0, w, static_cast<int>(len), nullptr, 0, nullptr, nullptr);
    if (n <= 0 || static_cast<size_t>(n) > cap) { return 0; }
    WideCharToMultiByte(CP_UTF8, 0, w, static_cast<int>(len), buf, n, nullptr, nullptr);
    for (int i = 0; i < n; ++i) {
        if (buf[i] == '\\') { buf[i] = '/'; }
    }
    return static_cast<size_t>(n);
}

bool move_path(const char *from, size_t flen, const char *to, size_t tlen) {
    std::wstring f = widen(from, flen), t = widen(to, tlen);
    return MoveFileExW(f.c_str(), t.c_str(), MOVEFILE_WRITE_THROUGH) != 0;
}

void console_utf8() {
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
}

bool enable_vt_stderr(int *cols) {
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD mode = 0;
    if (h == INVALID_HANDLE_VALUE || !GetConsoleMode(h, &mode)) { return false; }
    if (!(mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) &&
        !SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING)) {
        return false;
    }
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (GetConsoleScreenBufferInfo(h, &info)) { *cols = info.srWindow.Right - info.srWindow.Left + 1; }
    return true;
}

namespace {
struct ThreadStart {
    void (*fn)(void *);
    void *arg;
};

// A named WINAPI function, not a lambda: CreateThread takes a __stdcall routine, and a
// captureless lambda converts only to the default (__cdecl) convention, which differs
// on i686.
DWORD WINAPI thread_start(LPVOID raw) {
    auto *p = static_cast<ThreadStart *>(raw);
    p->fn(p->arg);
    delete p;
    return 0;
}
}  // namespace

void spawn_thread(void (*fn)(void *), void *arg, size_t stack_bytes) {
    auto *s = new ThreadStart{fn, arg};
    HANDLE h = CreateThread(nullptr, stack_bytes, thread_start, s,
                            STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr);
    if (h) { CloseHandle(h); } else { delete s; }
}

}  // namespace kairo::win32
#endif  // _WIN32
