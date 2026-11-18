// main.cpp: C++ news and deletes Kairo records; every block must come from
// (and go back to) shapes.k's Counting, the program's global allocator.
#include "shapes.k"
#include <iostream>
#include <new>

static void show(const char* what) {
    std::cout << what << " allocs=" << shapes::n_allocs() << " frees=" << shapes::n_frees()
              << " size=" << shapes::size_seen() << " align=" << shapes::align_seen() << "\n";
}

int main() {
    std::cout << std::unitbuf;
    int a0 = shapes::n_allocs(), f0 = shapes::n_frees();
    std::cout << "start " << a0 - a0 << " " << f0 - f0 << "\n";

    auto* p = new shapes::Point(3, 4);
    std::cout << "sum " << p->sum() << "\n";
    show("new-point");
    delete p;
    show("delete-point");

    auto* pa = new shapes::Point[3]{{1, 1}, {2, 2}, {3, 3}};
    show("new-array");
    delete[] pa;
    show("delete-array");

    auto* w = new shapes::Wide;
    std::cout << "wide-aligned " << ((reinterpret_cast<unsigned long>(w) % 64) == 0) << "\n";
    show("new-wide");
    delete w;
    show("delete-wide");

    auto* wa = new shapes::Wide[2];
    show("new-wide-array");
    delete[] wa;
    show("delete-wide-array");

    auto* b = new shapes::Box<int>(5);
    std::cout << "box " << shapes::box_get(b) << "\n";
    delete b;
    auto* bl = new shapes::Box<long>(6L);
    std::cout << "boxl " << bl->get() << "\n";
    delete bl;
    show("box");

    auto* s = new shapes::Shape(shapes::square(4));
    std::cout << "area " << shapes::area(s) << "\n";
    delete s;
    show("adt");

    auto* pr = new (std::nothrow) shapes::Pair{7, 8};
    show("nothrow");
    delete pr;

    alignas(shapes::Point) unsigned char buf[sizeof(shapes::Point)];
    auto* pp = new (buf) shapes::Point(5, 6);
    std::cout << "placement " << pp->sum() << "\n";
    pp->~Point();
    show("placement");

    // Kairo creates, C++ deletes; C++ news, Kairo destroys.
    shapes::Point* k = shapes::make_point(9);
    std::cout << "kairo-made " << k->sum() << "\n";
    delete k;
    show("cxx-delete-of-create");
    auto* c = new shapes::Point(1, 2);
    shapes::drop_point(c);
    show("destroy-of-cxx-new");
}
