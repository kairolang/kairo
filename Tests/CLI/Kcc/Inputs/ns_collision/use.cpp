// use.cpp: C++ calls a Kairo module whose name collides with a C global
// through its documented C++ namespace, `malloc_`, with <cstdlib>'s
// ::malloc still usable beside it.
#include "malloc.k"
#include <cstdlib>

int main() {
    void* p = ::malloc(16);
    int r = malloc_::helper() + (p != nullptr ? 2 : 0);
    ::free(p);
    return r;
}
