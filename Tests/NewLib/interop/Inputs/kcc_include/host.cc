#include "coll.k"

int main() {
    auto w = coll::words(3);
    auto t = coll::total(static_cast<decltype(w)&&>(w));
    auto m = coll::counts(coll::words(4));
    auto s = coll::keys(static_cast<decltype(m)&&>(m), coll::words(4));
    ::builtin::containers::vector::Vector<int> v = coll::nums();
    int two = coll::first_two(static_cast<decltype(v)&&>(v));
    return (t == 6 && coll::set_size(static_cast<decltype(s)&&>(s)) == 4 && two == 42) ? 0 : 1;
}
