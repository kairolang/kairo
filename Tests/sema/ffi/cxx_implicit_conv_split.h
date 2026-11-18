#pragma once
// For cxx_implicit_conv_split*.k: a converting constructor whose parameter
// the Kairo argument reaches only by a standard (widening) conversion.
struct Wide {
    long v;
    Wide(long x) : v(x) {}
};
inline int takew(Wide w) { return (int)w.v; }
// Two classes a literal reaches equally: the note lists both.
struct P { const char* s; P(const char* x) : s(x) {} };
struct Q { const char* s; Q(const char* x) : s(x) {} };
inline int pick(P) { return 1; }
inline int pick(Q) { return 2; }
