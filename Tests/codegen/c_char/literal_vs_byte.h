#pragma once
// A literal binds `const char *` in C++; the byte-pointer overloads beside it
// are not viable there, deleted or not.
inline int pick(const char *) { return 1; }
inline int pick(const unsigned char *) { return 2; }
inline int only_bytes(const unsigned char *s) { return s[0] == 'b' ? 4 : 0; }
struct Sink {
    int n = 0;
#if defined(__cpp_char8_t)
    Sink &operator<<(const char8_t *) = delete;
#endif
    Sink &operator<<(const unsigned char *) = delete;
    Sink &operator<<(const char *s) { n += 8; return *this; }
};
