#pragma once
#include <utility>

// A virtual method an override may replace, taking the object by `const T&`,
// by value through `const T*`, and by `T&`.
template <class T> struct Viewer {
    virtual ~Viewer() = default;
    virtual void look(const T &) {}
    virtual void look_ptr(const T *) {}
    virtual void poke(T &) {}
};

template <class T> void view_const(Viewer<T> *v, T &x) { v->look(x); v->look_ptr(&x); }
template <class T> void view_mut(Viewer<T> *v, T &x) { v->poke(x); }

// Calls through a function pointer: its prototype says what it can do.
template <class T> void reads_it(const T &) {}
template <class T> void takes_it(T &&x) { T s(std::move(x)); (void)s; }
template <class T> void pokes_it(T &) {}

template <class T> void via_const_ptr(T &x) {
    void (*fp)(const T &) = &reads_it<T>;
    fp(x);
}
template <class T> void via_rvalue_ptr(T &x) {
    void (*fp)(T &&) = &takes_it<T>;
    fp(std::move(x));
}
template <class T> void via_mut_ptr(T &x) {
    void (*fp)(T &) = &pokes_it<T>;
    fp(x);
}

// A lambda's body is read where it is written: a capture by reference is
// the object itself.
template <class T> void lambda_moves(T &x) {
    auto f = [&] { T s(std::move(x)); (void)s; };
    f();
}
template <class T> void lambda_reads(T &x) {
    auto f = [&] { (void)x; };
    f();
}

// `o.*pd` names a member of `o`.
template <class T> struct Holder { T t; };
template <class T> void member_ptr_moves(Holder<T> &h) {
    T Holder<T>::*pd = &Holder<T>::t;
    T s(std::move(h.*pd));
    (void)s;
}

// Recursion: `cyc_b` reaches the move only through `cyc_a`, which is
// still being answered when the walk of `cyc_a` first reads `cyc_b`.
template <class T> void cyc_a(T &x, int n);
template <class T> void cyc_b(T &x, int n) { cyc_a(x, n); }
template <class T> void cyc_a(T &x, int n) {
    if (n > 0) { cyc_b(x, n - 1); }
    T s(std::move(x));
    (void)s;
}

// A pointer to the object passed on by `T*&` / `T* const&`: what it points
// at is the object.
template <class T> void steal_through(T *const &q) { T s(std::move(*q)); (void)s; }
template <class T> void by_ptr_ref(T *p) { steal_through(p); }
template <class T> struct PtrViewer {
    virtual ~PtrViewer() = default;
    virtual void poke_ptr(T *const &) {}
};
template <class T> void view_ptr_ref(PtrViewer<T> *v, T *p) { v->poke_ptr(p); }
template <class T> void via_ptr_ref_fp(T *p) {
    void (*fp)(T *const &) = &steal_through<T>;
    fp(p);
}

// A call through a pointer to member function on the object.
template <class T> struct Box2 {
    T t;
    void take() { T s(std::move(t)); (void)s; }
};
template <class T> void member_fn_ptr(Box2<T> &b) {
    void (Box2<T>::*pm)() = &Box2<T>::take;
    (b.*pm)();
}
