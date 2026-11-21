// destructive_moves_exits.hh -- C++ helpers for destructive_moves_exits.k.
#pragma once
#include <stdexcept>

// Throws for a negative argument.
inline int dm_checked(int x) {
    if (x < 0) throw std::runtime_error("negative");
    return x;
}

// Calls back into Kairo, catching whatever the callback lets out.
inline int dm_guard(int (*f)(int), int x) {
    try { return f(x); } catch (const std::exception&) { return -1; }
}
