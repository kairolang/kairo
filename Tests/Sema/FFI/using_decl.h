// Corpus for using_decl.k: names a namespace takes from elsewhere with a
// using-declaration, the way libc++'s <cmath> puts ::sqrt in std.
#pragma once

inline int glob(int v) { return v + 1; }

namespace src {
    inline int f(int v) { return v * 2; }
    typedef long wide;
    struct Pt { int x; int y; };
    inline Pt mk() { Pt p; p.x = 1; p.y = 2; return p; }
}

namespace dst {
    using ::glob;
    using src::f;
    using src::wide;
    using src::Pt;
    using src::mk;
    inline int f(int a, int b) { return a + b; }
}
