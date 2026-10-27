// guard.hh -- C++ helpers for the noexcept-frame tests in this directory.
#pragma once
#include <stdexcept>

// Throws for a negative argument.
inline int checked(int x) {
    if (x < 0) throw std::runtime_error("negative");
    return x * 2;
}

// Throws and catches inside C++: nothing reaches the Kairo caller.
inline int contained(int x) {
    try { return checked(x); } catch (const std::exception&) { return -7; }
}

// Calls back into Kairo, catching whatever the callback lets out.
inline int guard(int (*f)(int), int x) {
    try { return f(x); } catch (const std::exception&) { return -1; }
}

// Throws std::logic_error for 13, std::runtime_error below 0 (via checked).
inline int unlucky(int x) {
    if (x == 13) throw std::logic_error("unlucky");
    return checked(x);
}
