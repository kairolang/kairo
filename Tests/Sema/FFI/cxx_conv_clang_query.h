#pragma once
// Shapes of real standard-library conversions and deduced return
// types, without any standard header.
template <class C> struct traits {};
template <class C> struct alloc { alloc() {} };

// basic_string: the converting constructor has a defaulted trailing
// parameter and is a member of a class template specialization.
template <class C, class A = alloc<C>> struct bstr {
    const C* p;
    bstr(const C* s, const A& = A()) : p(s) {}
};
using str = bstr<char>;
inline int slen(const str& s) { int n = 0; while (s.p[n]) ++n; return n; }

// basic_string_view with a defaulted traits parameter, and a second view
// (fmt::basic_string_view) whose constructor from it is a template.
template <class C, class T = traits<C>> struct bview {
    const C* p;
    bview(const C* s) : p(s) {}
};
using view = bview<char>;
template <class C> struct fview {
    const C* p;
    template <class S> fview(const S& s) : p(s.p) {}
};
inline int vlen(fview<char> v) { int n = 0; while (v.p[n]) ++n; return n; }

// Deduced return types: a free function, a member, a member of a class
// template specialization.
inline auto twice(int x) { return x * 2; }
struct Node {
    int v;
    auto get() const { return v + 1; }
};
inline Node make_node(int x) { return Node{x}; }
template <class T> struct Holder {
    T t;
    auto value() const { return t; }
};
inline Holder<int> make_holder(int x) { return Holder<int>{x}; }
