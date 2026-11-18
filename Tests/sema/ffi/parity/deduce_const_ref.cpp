// oracle for deduce_const_ref.k
#include "../deduce_const.h"

template <class A, class B> struct same       { static constexpr bool v = false; };
template <class A>          struct same<A, A> { static constexpr bool v = true;  };

void use_deduce() {
    const int c = 4;
    int v = 4;
    auto a = id(c);
    auto b = id(v);
    auto d = addr(v);
    auto e = addr(c);
    static_assert(same<decltype(a), int>::v,        "const T& against const int: T := int");
    static_assert(same<decltype(b), int>::v,        "const T& against int: T := int");
    static_assert(same<decltype(d), int*>::v,       "T& against int: T := int");
    static_assert(same<decltype(e), const int*>::v, "T& against const int: T := const int");
}
