// main.cpp: every block crosses the boundary once, made on one side and
// freed on the other with the matching C++ form (new / delete, new[] /
// delete[]). Gadget counts its live objects, so a constructor or destructor
// that did not run (an array freed as one object, a delete that was not a
// C++ delete) shows up as a wrong count. (The global operator new / delete
// cannot be replaced here: the runtime's allocator already defines them.)
#include "mem.k"
#include <cstdio>

static void show(const char* what) {
    std::printf("%s live=%d\n", what, gadget_live());
}

int main() {
    show("start");

    Gadget* g = mem::kairo_new_gadget(5);          // Kairo new, C++ delete
    std::printf("v %d\n", g->v);
    show("kairo-new");
    cxx_free_gadget(g);
    show("cxx-delete");

    Gadget* h = cxx_make_gadget(7);                // C++ new, Kairo delete
    show("cxx-new");
    mem::kairo_delete_gadget(h);
    show("kairo-delete");

    Gadget* ga = mem::kairo_new_gadgets(3);        // array, Kairo both sides
    std::printf("arr %d %d %d\n", ga[0].v, ga[1].v, ga[2].v);
    show("kairo-new-array");
    delete[] ga;                                   // ... freed by C++
    show("cxx-delete-array");

    Gadget* gb = new Gadget[2];                    // C++ new[], Kairo delete[]
    show("cxx-new-array");
    mem::kairo_delete_gadgets(gb);
    show("kairo-delete-array");

    int* xs = mem::kairo_new_ints(4);              // Kairo new[], C++ reads
    std::printf("ints %d %d %d %d\n", xs[0], xs[1], xs[2], xs[3]);
    delete[] xs;                                   // C++ delete[]
    show("ints-cxx-delete");

    int* ys = cxx_make_ints(3);                    // C++ new[], Kairo delete[]
    std::printf("sum %d\n", mem::kairo_sum_delete_ints(ys, 3));
    show("ints-kairo-delete");
    return 0;
}
