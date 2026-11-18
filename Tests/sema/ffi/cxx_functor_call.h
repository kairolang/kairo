#pragma once
// Function objects: classes with operator(), called as f(args) from Kairo.
struct Counter {
    int n = 0;
    int operator()(int x) { n += x; return n; }                // picked for a mutable object
    int operator()(int x) const { return 1000 + n + x; }       // picked for a const one
    int operator()(const char *) const { return -1; }          // overloaded on the parameter
    long operator()(long a, long b) const { return a * b; }    // overloaded on the arity
};
// Move-only: calling it must not move it.
struct Ticker {
    int k = 7;
    Ticker() = default;
    Ticker(Ticker &&) = default;
    Ticker(const Ticker &) = delete;
    int operator()() { return ++k; }
};
struct Holder { Counter c; };
