// oracle for ref_overload_prvalue.k
#include "../ref_overload.h"

template <class A, class B> struct same       { static constexpr bool v = false; };
template <class A>          struct same<A, A> { static constexpr bool v = true;  };

void use_prvalue() {
    auto r = f(T());
    static_assert(same<decltype(r), double>::v, "a prvalue binds T&&");
}
