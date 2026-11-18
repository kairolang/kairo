#pragma once
// C++ functions returning references, CALLED from Kairo: what
// already worked before `ffi::ref` existed, and must keep working.
inline int g_slot = 7;
inline int &ret_ref(int &a) { return a; }
inline const int &ret_cref(const int &a) { return a; }
inline int &&ret_mref(int &a) { return static_cast<int &&>(a); }
inline int &global_slot() { return g_slot; }
