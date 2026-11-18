// oracle for ref_overload_lvalue.k
#include "../ref_overload.h"

template <class A, class B> struct same       { static constexpr bool v = false; };
template <class A>          struct same<A, A> { static constexpr bool v = true;  };

void use_lvalue() {
    T t = T();
    auto r = f(t);
    static_assert(same<decltype(r), int>::v, "an lvalue binds const T&");
}
