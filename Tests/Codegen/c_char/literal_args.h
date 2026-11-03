// literal_args.k's C side: a `const char *` and a `const unsigned char *`
// parameter, each reading its NUL-terminated argument.
#pragma once
#include <string.h>
static inline int count_c(const char *s) { return (int)strlen(s); }
static inline int first_u(const unsigned char *s) { return s[0]; }
