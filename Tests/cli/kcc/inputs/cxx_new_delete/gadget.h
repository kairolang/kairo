// gadget.h: a C++ type C++ allocates and frees itself.
#pragma once
struct Gadget {
    int v;
    static inline int live = 0;
    Gadget() : v(1) { ++live; }
    explicit Gadget(int x) : v(x) { ++live; }
    ~Gadget() { --live; }
};
inline int gadget_live() { return Gadget::live; }
inline Gadget* cxx_make_gadget(int v) { return new Gadget(v); }
inline void cxx_free_gadget(Gadget* g) { delete g; }
inline int* cxx_make_ints(int n) { int* p = new int[n]; for (int i = 0; i < n; ++i) p[i] = i + 1; return p; }
