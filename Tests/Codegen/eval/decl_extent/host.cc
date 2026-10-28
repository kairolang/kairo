// C++ host for use.k: lib's Table, whose field length C++ computes from an
// eval fn, laid out through `#include "lib.k"` (EVAL.md §11): the include
// stream defines `twice` ahead of the class, as a Kairo TU does.
#include "lib.k"

static_assert(sizeof(::lib::Table) == 4 * sizeof(int));

int main() { return (sizeof(::lib::Table) / sizeof(int) == 4) ? 42 : 1; }
