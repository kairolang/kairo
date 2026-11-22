#pragma once
// Overloads that differ only in enable_if, the shape of libc++'s
// `_LIBCPP_PREFERRED_OVERLOAD` memchr beside the C library's.
#define PREFERRED __attribute__((__enable_if__(true, "")))
#define NEVER __attribute__((__enable_if__(false, "never selected")))

// The same parameters three times: the true one is selected, the false one
// is no candidate.
inline int pick(int) { return 1; }
inline long pick(int) PREFERRED { return 2; }
inline short pick(int) NEVER { return 3; }

// A false condition alone: the plain one is selected.
inline int only_false(int) { return 1; }
inline int only_false(int) NEVER { return 3; }

// A false condition with the better conversion: still no candidate.
inline int ranked(long) { return 1; }
inline int ranked(int) NEVER { return 4; }

// A better conversion beats enable_if, which only breaks a tie.
inline int conv(int) { return 5; }
inline int conv(long) PREFERRED { return 6; }

// memchr's shape: a C declaration and a preferred C++ overload returning
// const.
extern "C" inline void* find_byte(const void* p, int, unsigned long) { return (void*)p; }
inline const void* find_byte(const void* p, int, unsigned long) PREFERRED { return (const char*)p + 1; }
