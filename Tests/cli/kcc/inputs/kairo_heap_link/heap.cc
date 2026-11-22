// Prints which heap served malloc and operator new. mi_is_in_heap_region is
// declared weak, so this file also links without the Kairo runtime, where
// the symbol stays null.
#include <cstdio>
#include <cstdlib>

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
    std::printf("malloc %s\n", heap_of(m));
    std::printf("new %s\n", heap_of(n));
    delete n;
    std::free(m);
    return 0;
}
