#pragma once
struct Base { int v = 1; Base() = default; Base(const Base&) = delete; virtual ~Base() {} };
struct Derived : Base { Derived() = default; Derived(const Derived&) = delete; };
inline Derived &getd() { static Derived d; return d; }
inline int take_ref(Base &b) { return b.v; }
inline int take_two(Base &a, Base &b, int x) { return a.v + b.v + x; }
struct NC { NC() = default; NC(const NC&) = delete; int n = 3; };
inline NC &getnc() { static NC d; return d; }
inline int take_nc(NC n) { return n.n; }
struct NCH { NCH() = default; NCH(const NCH&) = delete; NCH(NCH&&) = default; int n = 4; };
struct Stream { Stream() = default; Stream(const Stream&) = delete; int w = 1; };
inline Stream &getstream() { static Stream s; return s; }
struct Sink { Sink(Stream &s) : w(s.w) {} int w; };
struct Holder { Holder() = default; void push_back(const NCH &) {} void push_back(NCH &&) {} };
inline NCH &getnch() { static NCH d; return d; }
template <class T, class... A> T *mk(A &&...a) { return new T(static_cast<A &&>(a)...); }
inline Stream &getstream2() { static Stream s; return s; }
struct Sink3 { Sink3(Stream &s, int a, Stream &t) : w(s.w + a + t.w) {} int w; };
