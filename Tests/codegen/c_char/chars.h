// C++ that hands Kairo C strings and plain chars. Imported by the tests in
// this directory: `const char*` must reach Kairo as `*const c_char` and go
// back to C++ as `const char*`, and `char`, `signed char` and `unsigned
// char` are three types, so `which` is three overloads.
#pragma once

inline const char *greet() { return "hello"; }

inline int which(char) { return 1; }
inline int which(signed char) { return 2; }
inline int which(unsigned char) { return 3; }

inline char first(const char *s) { return s[0]; }

inline int count_of(const char *s, char c) {
    int n = 0;
    for (; *s; ++s) { if (*s == c) { ++n; } }
    return n;
}

inline void fill(char *out, char c, int n) {
    for (int i = 0; i < n; ++i) { out[i] = c; }
    out[n] = 0;
}
