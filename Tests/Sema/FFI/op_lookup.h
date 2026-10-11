// Corpus for op_lookup.k: one shape per C++ operator-lookup rule.
#pragma once
#include "op_lookup_fwd.h"

namespace ol {
// A free operator TEMPLATE: bound by its operator name, not as `operator!=`.
template <class T> struct Tpl { T v; };
template <class T> bool operator!=(const Tpl<T>& a, const Tpl<T>& b) { return a.v != b.v; }

// Two templates that both match exactly: partial ordering picks the first,
// which is more specialized. `!=` has only non-viable overloads in scope,
// so C++20 rewrites it as `!(a == b)`.
template <class T> struct Ord { T v; };
template <class T1> bool operator==(const Ord<T1>& a, const Ord<T1>& b) { return a.v == b.v; }
template <class T1, class T2> bool operator==(const Ord<T1>& a, const Ord<T2>& b) { return a.v == b.v; }
struct Other {};
bool operator!=(const Other&, const Other&);

// The class forward-declared in another header than its operator: ADL
// searches every reopening of `ol`, not the record's own block.
template <class T> struct Fwd { T v; };
template <class T> bool operator<(const Fwd<T>& a, const Fwd<T>& b) { return a.v < b.v; }

// A hidden friend: found only by ADL through the class.
struct Hid {
    int v;
    friend bool operator==(const Hid& a, const Hid& b) { return a.v == b.v; }
};

// Unary `*` and prefix `++` as members.
struct Deref {
    int v;
    int& operator*() { return v; }
    Deref& operator++() { ++v; return *this; }
};

inline Tpl<int> tpl(int x)   { return Tpl<int>{x}; }
inline Ord<int> ord(int x)   { return Ord<int>{x}; }
inline Fwd<int> fwd(int x)   { return Fwd<int>{x}; }
inline Hid      hid(int x)   { return Hid{x}; }
inline Deref    deref(int x) { return Deref{x}; }
}
