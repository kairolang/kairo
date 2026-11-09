#pragma once
// C++ `T&` parameters, which Kairo reads as `@inout x: T`.
inline int inc(int &x) { return ++x; }
struct B { int n = 0; };
struct D : B { int extra = 3; };
inline int bump(B &b) { b.n += 10; return b.n; }
inline int pick(int &) { return 1; }
inline int pick(int *) { return 2; }
