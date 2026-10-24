#include "ffi/ffiuse.k"

int main() {
    Vec2 v{1, 2};
    return ffiuse::len2(v) + ffiuse::twice_c(3);
}
