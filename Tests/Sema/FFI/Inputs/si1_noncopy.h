#pragma once
struct Base { int v = 1; Base() = default; Base(const Base&) = delete; virtual ~Base() {} };
struct Derived : Base { Derived() = default; Derived(const Derived&) = delete; };
inline Derived &getd() { static Derived d; return d; }
inline int take_ref(Base &b) { return b.v; }
inline int take_two(Base &a, Base &b, int x) { return a.v + b.v + x; }
struct NC { NC() = default; NC(const NC&) = delete; int n = 3; };
inline NC &getnc() { static NC d; return d; }
inline int take_nc(NC n) { return n.n; }
