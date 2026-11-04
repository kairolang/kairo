#pragma once
struct Err { Err() = default; Err(Err&&) = default; Err(const Err&) = delete; int x = 0; };
void consume(Err e);
template <class T> struct Exp { T v; T& operator*() { return v; } };
struct Mem { Mem() = default; Mem(Mem&&) = default; Mem(const Mem&) = delete; };
