#pragma once
// Function templates over a class template, called with a DERIVED class.
template <class T> struct Base { T v; };
struct Derived : Base<int> { int extra = 0; };
template <class T> T get(Base<T> &b) { return b.v + 1; }
template <class T> int pick(Base<T> &) { return 10; }
template <class T> int pick(Base<T> &&) { return 20; }
