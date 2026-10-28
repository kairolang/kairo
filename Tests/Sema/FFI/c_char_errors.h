// c_char_errors.k's C++ side: a C string parameter, and one that really is
// `const signed char*`, which stays `*const i8`.
#pragma once
inline int take(const char *s) { return s[0]; }
inline int take_signed(const signed char *s) { return s[0]; }
