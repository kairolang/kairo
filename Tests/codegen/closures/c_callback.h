/* C callbacks for passed.k: a C function pointer parameter. */
#pragma once
static inline int c_apply(int (*f)(int), int x) { return f(x); }
