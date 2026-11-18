// where_main.cpp: a C++ host calling Kairo `where` dispatch groups by their
// public names (guards.k), which dispatch on the guards exactly as a Kairo
// call does. A method group's candidates are private members.
#include "guards.k"
#include <iostream>

// A free group's candidates are not declared to the host at all: if the
// include declared `int __kairo_where_categorize_0(int)`, this declaration,
// differing only in its return type, would not compile.
namespace guards { void __kairo_where_categorize_0(int); }

template <class M>
constexpr bool candidate_visible = requires(M m) { m.__kairo_where_read_0(1); };
static_assert(!candidate_visible<guards::Meter>, "a method group's candidates are private");

int main() {
    std::cout << std::unitbuf;
    std::cout << "categorize " << guards::categorize(500) << " " << guards::categorize(5)
              << " " << guards::categorize(-5) << "\n";
    std::cout << "divide " << guards::safe_divide(10, 2) << " " << guards::safe_divide(10, 0) << "\n";
    guards::Meter m(10);
    std::cout << "read " << m.read(3) << " " << m.read(30) << "\n";
    return 0;
}
