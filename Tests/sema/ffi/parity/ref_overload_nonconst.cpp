// oracle for ref_overload_nonconst.k
#include "../ref_overload.h"

template <class A, class B> struct same       { static constexpr bool v = false; };
template <class A>          struct same<A, A> { static constexpr bool v = true;  };

void use_nonconst() {
    T t = T();
    auto r = h(t);
    static_assert(same<decltype(r), double>::v, "a non-const lvalue binds T&");
}
