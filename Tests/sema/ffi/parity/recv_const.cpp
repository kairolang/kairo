// oracle for recv_const.k
#include "../recv_const.h"

template <class A, class B> struct same       { static constexpr bool v = false; };
template <class A>          struct same<A, A> { static constexpr bool v = true;  };

void use_buf(Buf* b, const Buf* k) {
    auto p = b->data();
    auto q = k->data();
    auto n = k->size();
    static_assert(same<decltype(p), int*>::v,       "a non-const object prefers data()");
    static_assert(same<decltype(q), const int*>::v, "a const object has only data() const");
    k->clear();   // expected-error: clear() is not const
}
