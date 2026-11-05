#pragma once
struct Ctx { Ctx() = default; Ctx(const Ctx&) = delete; int v = 2; int n() { return v; } };
inline int use(Ctx &c, int x) { return c.v + x; }
struct Cnt { int v = 0; int bump() { return ++v; } };
inline int add(Cnt &c, int x) { c.v += x; return c.v; }
struct SM { SM(int, int) {} SM(const SM&) = delete; int loc(int x) { return x + 1; } };
struct Info { SM *sm; SM &getSM() const { return *sm; } int getLoc() const { return 3; } };
