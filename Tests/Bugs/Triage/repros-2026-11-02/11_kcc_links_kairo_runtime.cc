// kcc on a pure C++ input links Kairo's runtime, and with the mimalloc
// runtime that silently swaps the program's malloc. Expected: a C++-only
// kcc build uses the target's own C/C++ runtime (or says otherwise).
// Actual: `nm a.out | grep mi_malloc` finds mimalloc; binary-trees in C++
// built with kcc runs on mimalloc (4.1 s vs 7.2 s with host clang).
// Check: kcc -O2 11_kcc_links_kairo_runtime.cc -o a.out; nm a.out | grep -c mi_malloc
#include <cstdio>
#include <memory>
int main() {
    auto p = std::make_unique<int>(42);
    std::printf("%d %p\n", *p, (void*)p.get());   // escapes, so the allocation stays
}
