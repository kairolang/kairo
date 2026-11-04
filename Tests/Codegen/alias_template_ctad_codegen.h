#pragma once
template <class T> struct Box { T v; Box(T& x) : v(x) {} };
template <class T> using BoxA = Box<T>;
struct Mu { int n = 0; };
