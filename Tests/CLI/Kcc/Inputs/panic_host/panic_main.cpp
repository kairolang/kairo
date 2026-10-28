// panic_main.cpp: two Kairo modules included into one C++ TU, each returning
// a Panic<...> whose set holds i64, so each include needs i64's type-id
// specialization; it is written once. The host reads the tags as Kairo
// wrote them: an Err's tag is its type's id, the same in both sets.
#include "left.k"
#include "right.k"
#include <cstdio>

int main() {
    auto a = left::left(true);
    auto b = right::right(true);
    auto c = right::right(false);
    unsigned ta = static_cast<unsigned>(a.__kairo_tag);
    unsigned tb = static_cast<unsigned>(b.__kairo_tag);
    unsigned tc = static_cast<unsigned>(c.__kairo_tag);
    std::printf("same %d i64 %d i8 %d ok %d\n", ta == tb, ta == ::__kairo_type_id<long>,
                tc == ::__kairo_type_id<signed char>, static_cast<unsigned>(left::left(false).__kairo_tag) == 0);
    return 0;
}
