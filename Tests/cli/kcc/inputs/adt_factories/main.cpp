// main.cpp: C++ builds every variant of packet.k's ADT enums through the
// factories, named exactly after the variants, and hands them to Kairo.
#include "packet.k"
#include <iostream>

int main() {
    std::cout << std::unitbuf;
    // A generic enum, at an instance the module instantiated (extern
    // template) and at one it never names.
    std::cout << "burst " << packet::sum_burst(packet::Frame<int>::Burst(20, 4)) << "\n";
    std::cout << "code " << packet::sum_burst(packet::Frame<int>::Code(5)) << "\n";
    std::cout << "idle " << packet::sum_burst(packet::Frame<int>::Idle()) << "\n";
    std::cout << "wide " << packet::sum_wide(packet::Frame<long>::Burst(3000000000L, 2)) << "\n";
    // Assignment over an existing value, the README's shape.
    packet::Frame<int> f = packet::Frame<int>::Idle();
    f = packet::Frame<int>::Burst(1, 2);
    std::cout << "assigned " << packet::sum_burst(f) << "\n";
    // Non-generic, with a string payload.
    std::cout << "ok " << packet::res_code(packet::Res::Ok(9)) << "\n";
    std::cout << "err " << packet::res_code(packet::Res::Err(::builtin::string::string(reinterpret_cast<const unsigned char*>("four")), 30)) << "\n";
    std::cout << "nothing " << packet::res_code(packet::Res::Nothing()) << "\n";
    // Niche-filled: the partial specialization has them too.
    int x = 42;
    static_assert(sizeof(packet::Maybe<int*>) == sizeof(int*), "niche-filled");
    std::cout << "some " << packet::deref_or(packet::Maybe<int*>::Some(&x), 0) << "\n";
    std::cout << "none " << packet::deref_or(packet::Maybe<int*>::None(), 11) << "\n";
}
