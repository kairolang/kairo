#pragma once
// Release/acquire flag for mi_threads.k: Kairo cannot call the __atomic
// builtins directly yet (R057E).
inline void at_store1(int* p) { __atomic_store_n(p, 1, __ATOMIC_RELEASE); }
inline int  at_load(int* p)   { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
