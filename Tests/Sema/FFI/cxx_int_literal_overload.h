#pragma once
inline int f(int) { return 1; }
inline int f(unsigned) { return 2; }
inline int f(long long) { return 3; }
inline int f(double) { return 4; }
inline int f(bool) { return 5; }
inline int g(unsigned) { return 2; }
inline int g(double) { return 4; }
