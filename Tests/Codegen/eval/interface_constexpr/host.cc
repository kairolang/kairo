// C++ host for use.k: the eval bindings of lib.k are constant expressions
// to C++ through `#include "*.k"` (EVAL.md 1.2b).
#include "lib.k"

static_assert(::lib::N == 8);
static_assert(::lib::NEXT == 9);
static_assert(::lib::TAG.len == 3);
static int arr[::lib::N];

int main() { return (sizeof(arr) / sizeof(arr[0]) == 8) ? 42 : 1; }
