/* Corpus for defaults/ffi_defaults.k and ffi_defaults_skip.k. Inline, so no
 * object to link: the point is that clang, not Kairo, applies the default. */
#pragma once
inline int add_to(int a, int b = 40) { return a + b; }
inline int span3(int a, int b = 2, int c = 3) { return a * 100 + b * 10 + c; }
