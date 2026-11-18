// The C++ side of adl_lookup.k: a function and an operator that only
// argument-dependent lookup finds from outside `ns`.
#pragma once

namespace ns {
struct V {
    int x = 0;
};

inline int tag(V v, int k) { return v.x + k; }
inline V operator-(V a) {
    V r;
    r.x = -a.x;
    return r;
}

// Hidden friends: only argument-dependent lookup finds them, and they
// cannot be named with a qualifier.
struct Seq {
    int v[2] = {7, 8};
    friend int* begin(Seq& s) { return s.v; }
    friend int* end(Seq& s) { return s.v + 2; }
};
} // namespace ns
