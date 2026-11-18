// C++ arithmetic that a Kairo TU compiles alongside its own: the same
// expressions as the .k files beside it, under C++'s FP semantics.
#pragma once
#include <math.h>
inline double h_mac(double a, double b, double c) { return a * b + c; }
inline double h_sqrt(double x) { return sqrt(x); }
template <class T> T t_mac(T a, T b, T c) { return a * b + c; }
