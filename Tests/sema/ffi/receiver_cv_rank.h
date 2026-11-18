#pragma once
// Methods that differ only in the implicit object's volatile.
struct Cell {
    int get() const { return 1; }
    int get() const volatile { return 2; }
    int put(int) { return 3; }
    int put(int) volatile { return 4; }
    // Neither qualification contains the other: ambiguous in C++ too.
    int amb() const { return 5; }
    int amb() volatile { return 6; }
};
