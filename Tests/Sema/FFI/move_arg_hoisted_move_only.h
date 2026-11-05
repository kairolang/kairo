#pragma once
#include <memory>
struct Buf { int n; };
struct SM { int take(std::unique_ptr<Buf> b, int x) { return b->n + x; } };
inline std::unique_ptr<Buf> mk(int n) { return std::unique_ptr<Buf>(new Buf{n}); }
inline int loc(int a) { return a; }
