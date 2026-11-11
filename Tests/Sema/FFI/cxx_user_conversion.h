#pragma once
// A string_view-like class: implicit ctor from const char*.
struct View {
    const char* p;
    View(const char* s) : p(s) {}
};
inline int len(View v) { int n = 0; while (v.p[n]) ++n; return n; }
inline int len_ref(const View& v) { return len(v); }
struct A { int v; A(int x) : v(x) {} };
struct B { int w; B(const A& a) : w(a.v) {} };
inline int take(B b) { return b.w; }
struct C { int z; };
struct D { int q; D(int x) : q(x) {} operator C() const { return C{q * 2}; } };
inline int takec(C c) { return c.z; }
struct E { int e; explicit E(const A& a) : e(a.v) {} };
inline int takee(E e) { return e.e; }
struct Result { int status; operator bool() const { return status == 0; } };
inline Result load(int s) { return Result{s}; }
