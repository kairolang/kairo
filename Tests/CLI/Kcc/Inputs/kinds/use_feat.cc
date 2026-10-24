#include "feat.k"
#include <cstdio>
#include <type_traits>

int main() {
    // enum with an explicit underlying type
    static_assert(std::is_same_v<std::underlying_type_t<feat::Color>, unsigned char>);
    std::printf("color %d\n", static_cast<int>(feat::Color::Blue));
    // ADT built and inspected through Kairo functions
    std::printf("area %d\n", feat::area(feat::make_square(4)));
    // nested module
    std::printf("deep %d\n", feat::inner::deep(3));
    // struct operator and extension method
    feat::V2 a; a.x = 1; a.y = 2;
    feat::V2 b; b.x = 3; b.y = 4;
    feat::V2 c = a + b;
    std::printf("sum %d %d dot %d\n", c.x, c.y, feat::__kairo_ext_V2::dot(&a, b));
    // const field set in ctor, static field, @inout, const method
    feat::Counter k1(7);
    feat::Counter k2(8);
    int kk = 1;
    k1.bump(kk);
    std::printf("counter id %d n %d k %d made %d\n", k1.id, k1.get(), kk, feat::Counter::made);
    // virtual dispatch across the boundary
    feat::Derived d;
    feat::Base* bp = &d;
    std::printf("who %d b %d\n", bp->who(), bp->b);
    // tuple return
    auto t = feat::pair(5);
    auto [p0, p1] = t;
    std::printf("pair %d %d\n", p0, p1);
    return 0;
}
