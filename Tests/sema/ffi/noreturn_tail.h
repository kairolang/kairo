// noreturn_tail.k's C++ side: one function that never returns and says
// so, and one that returns.
#pragma once
[[noreturn]] inline void stop_here(int code) { __builtin_trap(); }
inline int keep_going(int code) { return code; }
