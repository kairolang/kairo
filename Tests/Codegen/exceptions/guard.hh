// guard.hh -- C++ helpers for the noexcept-frame tests in this directory.
#pragma once
#include <cstdio>
#include <stdexcept>

// Prints "<tag> <value>" and flushes: a test that ends in std::terminate
// still has every line written before the abort.
inline void say(int tag, int v) {
    std::printf("%d %d\n", tag, v);
    std::fflush(stdout);
}

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

// Calls back into Kairo through a plain C function pointer, nothing caught.
inline int apply(int (*f)(int), int x) { return f(x); }

// Throws std::logic_error for 13, std::runtime_error below 0 (via checked).
inline int unlucky(int x) {
    if (x == 13) throw std::logic_error("unlucky");
    return checked(x);
}
