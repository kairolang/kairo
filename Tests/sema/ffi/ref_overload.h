// Corpus for the reference-binding parity cases (Tests/sema/ffi/parity/ref_*.k):
// overload sets that differ ONLY in reference kind, so which callee C++ picks
// depends on the argument's value category, not on its type. Each overload
// returns a different type, which is how a --print-sema check sees the pick.
#pragma once

struct T {};

// (const T&, T&&): a prvalue picks T&&, an lvalue picks const T&.
int f(const T&);
double f(T&&);

// (T&, const T&): a non-const lvalue picks T&.
double h(T&);
int h(const T&);

// T& alone: nothing but a non-const lvalue binds it.
int takes_ref(int&);
