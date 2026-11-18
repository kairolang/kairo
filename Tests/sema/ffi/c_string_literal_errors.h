// c_string_literal_errors.k's C side: a C string parameter, and one that
// may be written, which no literal's read-only bytes may reach.
#pragma once
inline void fill(char *buf) { buf[0] = 0; }
inline int count(const char *s) { int n = 0; while (s[n]) ++n; return n; }
