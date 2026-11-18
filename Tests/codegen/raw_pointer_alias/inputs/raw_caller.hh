#pragma once
// C++ declarations over plain pointers that Kairo calls with `unsafe *i32`.
extern "C" int ksum(int *p, decltype(sizeof(0)) n);
int call_ksum(int *p, decltype(sizeof(0)) n);
inline int cxx_first(const int *p) { return *p; }
