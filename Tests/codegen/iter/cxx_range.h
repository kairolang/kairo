// Corpus for cxx_range.k: the two class shapes libc++ does not cover.
#pragma once

namespace rr {
// No members: [stmt.ranged] falls back to begin(r) / end(r), found by ADL.
struct Free { int v[3] = {1, 2, 3}; };
inline int* begin(Free& f) { return f.v; }
inline int* end(Free& f) { return f.v + 3; }

// Hidden friends: found only by ADL, and not members, so [stmt.ranged]
// takes the free form.
struct Hf {
    int v[2] = {7, 8};
    friend int* begin(Hf& h) { return h.v; }
    friend int* end(Hf& h) { return h.v + 2; }
};

// Members whose iterator is a raw pointer, stepped by the builtin `++`.
struct Ptrs {
    int v[2] = {4, 5};
    int* begin() { return v; }
    int* end() { return v + 2; }
};
}
