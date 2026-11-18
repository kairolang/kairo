#pragma once
// A C++ class whose const and non-const operator[] return different
// types and values, so the Kairo side only type-checks when Sema chose the
// overload C++ calls, and the exit code shows which one ran.
struct P921Tag {
    int v;
};

struct P921Pair {
    int slot = 0;
    int& operator[](int) { slot = 10; return slot; }
    P921Tag operator[](int) const { return P921Tag{1}; }
};
