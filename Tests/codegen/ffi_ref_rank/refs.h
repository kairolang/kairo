// Overloads C++ orders by reference binding alone ([over.ics.rank]/3.2.3
// and 3.2.6). Each returns a distinct number so a run test sees the pick.
#pragma once
#include <utility>

// An rvalue prefers T&& to const T&; an lvalue can only take const T&.
inline int bind(const int&) { return 1; }
inline int bind(int&&) { return 2; }

// A non-const lvalue prefers T& to const T& (3.2.6); anything else takes
// the const one.
inline int lbind(int&) { return 3; }
inline int lbind(const int&) { return 4; }

inline int g() { return 5; }                                   // a prvalue
inline int& gl() { static int x = 0; return x; }               // an lvalue
inline int&& gx() { static int x = 0; return std::move(x); }   // an xvalue
inline const int& gcl() { static int x = 0; return x; }        // a const lvalue

// A converted argument binds the temporary the conversion makes, an rvalue
// whatever the argument was.
inline int wide(const long long&) { return 1; }
inline int wide(long long&&) { return 2; }

// A move-only type: Kairo passes an lvalue of it by moving.
struct Mv {
    int v = 7;
    Mv() = default;
    Mv(Mv&&) = default;
    Mv(const Mv&) = delete;
};
inline int sink(const Mv&) { return 1; }
inline int sink(Mv&&) { return 2; }

// The implicit object. With ref-qualifiers it binds like any reference
// parameter (3.2.3 applies); without them it does not, and an rvalue
// object binds a plain method ([over.match.funcs]/5).
struct Obj {
    int q() & { return 1; }
    int q() && { return 2; }
    int q() const & { return 3; }
    int r() { return 4; }
    int r() const { return 5; }
};
inline Obj make_obj() { return Obj(); }

// Only one qualifier each, so the wrong object has no candidate left.
struct Only {
    int t() && { return 1; }
    int u() & { return 2; }
};
inline Only make_only() { return Only(); }
