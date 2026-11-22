#include "vp.k"
#include <cstdio>
#include <utility>

static int read_id(vp::C&& c) { return c.id; }

int main() {
    {
        vp::C a(1);
        int k = vp::keep(std::move(a));
        std::printf("keep %d live %d\n", k, a.id);
    }
    std::printf("keep moved lvalue: %d\n", vp::count());
    { int k = vp::keep(vp::C(2)); std::printf("keep %d\n", k); }
    std::printf("keep prvalue: %d\n", vp::count());
    {
        vp::C a(3);
        vp::C b = vp::take(std::move(a));
        std::printf("take %d left %d\n", b.id, a.id);
    }
    std::printf("take: %d\n", vp::count());
    {
        vp::C a(4);
        vp::maybe(std::move(a), false);
        std::printf("maybe false left %d\n", a.id);
    }
    std::printf("maybe false: %d\n", vp::count());
    {
        vp::C a(5);
        vp::maybe(std::move(a), true);
    }
    std::printf("maybe true: %d\n", vp::count());
    {
        vp::C r = vp::pass<vp::C>(vp::C(6));
        int n = vp::pass<int>(7);
        std::printf("pass %d %d\n", r.id, n);
    }
    std::printf("pass: %d\n", vp::count());
    {
        vp::C a(8);
        vp::Holder h(std::move(a));
        std::printf("holder %d left %d\n", h.c.id, a.id);
    }
    std::printf("holder: %d\n", vp::count());
    {
        int k = vp::apply(&read_id, vp::C(9));
        std::printf("apply %d\n", k);
    }
    std::printf("apply: %d\n", vp::count());
    return 0;
}
