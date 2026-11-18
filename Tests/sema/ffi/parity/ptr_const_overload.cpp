// oracle for ptr_const_overload.k
#include "../ptr_const.h"

template <class A, class B> struct same       { static constexpr bool v = false; };
template <class A>          struct same<A, A> { static constexpr bool v = true;  };

void use_ptrs() {
    int x = 1;
    int* p = &x;
    const int* q = &x;
    auto a = g(p);
    auto b = g(q);
    auto c = h(&p);
    static_assert(same<decltype(a), long>::v, "*i32 is Exact for g(int*)");
    static_assert(same<decltype(b), int>::v,  "only g(const int*) takes a *const i32");
    static_assert(same<decltype(c), int>::v,  "int** -> const int* const* is a qualification conversion");
    int** r = &p;
    g2(r);   // expected-error: int** -> const int** adds const at level 2 without const above
}
