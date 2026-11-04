#pragma once
struct Tag { int n = 5; };
template <class T> struct WT { T v; WT(Tag t) noexcept : v(t.n) {} };
struct W { int v; W(Tag t) noexcept : v(t.n + 1) {} };
