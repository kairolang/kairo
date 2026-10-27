// host.cc: one C++ TU including two Kairo headers that both expose
// Panic<i32, Shared> (kcc_panic_two_headers.k).
#include "left.hh"
#include "right.hh"
#include <cstdio>

int main() {
    auto a = left::left(-1);
    auto b = right::right(-1);
    std::printf("one type %d tag is id %d same tag %d\n", __is_same(decltype(a), decltype(b)),
                static_cast<unsigned>(a.__kairo_tag) == ::builtin::type_id<errs::Shared>,
                static_cast<unsigned>(a.__kairo_tag) == static_cast<unsigned>(b.__kairo_tag));
    try { ::builtin::value_or_throw(b); }
    catch (const ::builtin::panic_error<errs::Shared>& e) { std::printf("code %d what: %s\n", e.error.code, e.what()); }
    std::printf("values %d %d\n", ::builtin::value_or_throw(left::left(1)), ::builtin::value_or_throw(right::right(1)));
    return 0;
}
