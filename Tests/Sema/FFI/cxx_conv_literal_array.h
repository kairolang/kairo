#pragma once
struct fstr {
    const char* p; int n;
    template <int N> consteval fstr(const char (&s)[N]) : p(s), n(N - 1) {}
};
inline int flen(fstr f) { return f.n; }
