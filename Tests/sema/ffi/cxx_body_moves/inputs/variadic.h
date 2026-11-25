#pragma once
#include <cstdarg>
#include <cwchar>
#include <utility>

// A C `...` argument has no declared type: the body reads it back with
// `va_arg` as whatever type it names.
template <class T> void steal_va(int n, ...) {
    va_list ap;
    va_start(ap, n);
    T *p = va_arg(ap, T *);
    T s(std::move(*p));
    (void)s;
    va_end(ap);
}
template <class T> void read_va(int n, ...) {
    va_list ap;
    va_start(ap, n);
    (void)va_arg(ap, const T *);
    va_end(ap);
}

template <class T> void pass_va(T *p) { steal_va<T>(1, p); }
template <class T> void pass_va_ref(T &x) { steal_va<T>(1, &x); }
template <class T> void pass_va_const(T *p) { read_va<T>(1, static_cast<const T *>(p)); }
template <class T> void pass_va_none(T *p) { read_va<T>(0); (void)p; }

// A C library variadic with no visible body (not a clang builtin).
template <class T> void pass_va_lib(T *p) {
    wchar_t buf[32];
    swprintf(buf, 32, L"%p", p);
}
