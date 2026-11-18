// C++ helpers for callee_destroys.k.
#pragma once
#include <stdexcept>

// Throws for a negative argument.
inline int checked(int x) {
    if (x < 0) throw std::runtime_error("negative");
    return x;
}

// Calls back into Kairo, catching whatever the callback lets out.
inline int guard(int (*f)(int), int x) {
    try { return f(x); } catch (const std::exception&) { return -1; }
}
