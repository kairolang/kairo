// Prints which heap served malloc, operator new and a block Kairo code
// allocated (blk::make). mi_is_in_heap_region is declared weak; the Kairo code
// links the runtime, so it is defined in every link of this file.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "blk.k"

extern "C" __attribute__((weak)) bool mi_is_in_heap_region(const void *p);

static const char *heap_of(const void *p) {
    if (mi_is_in_heap_region == nullptr) {
        return "c-library";
    }
    return mi_is_in_heap_region(p) ? "kairo" : "foreign";
}

int main() {
    void *m = std::malloc(48);
    int *n = new int(5);
    std::uintptr_t k = blk::make();
    std::printf("malloc %s\n", heap_of(m));
    std::printf("new %s\n", heap_of(n));
    std::printf("kairo %s\n", heap_of(reinterpret_cast<const void *>(k)));
    delete n;
    std::free(m);
    return 0;
}
