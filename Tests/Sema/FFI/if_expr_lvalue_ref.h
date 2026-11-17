#pragma once
inline void lone(int& x) { x += 1; }
inline int both(int& x) { return 1; }
inline int both(const int& x) { return 2; }
