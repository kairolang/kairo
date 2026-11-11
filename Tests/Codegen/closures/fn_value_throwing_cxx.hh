#pragma once
inline int checked(int x) { if (x < 0) throw x; return x * 2; }
inline int guard(int (*f)(int), int x) { try { return f(x); } catch (int) { return -1; } }
