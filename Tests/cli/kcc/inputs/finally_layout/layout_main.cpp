// layout_main.cpp: the union storage of a local `finally()` ends is the
// local's own layout (Compiler/Spec/Lowering.md#union-storage-locals),
// checked against the helpers the Kairo half emits into this TU.
#include "wide.k"
#include <cstddef>
#include <cstdio>
#include <type_traits>
#include <utility>

using W = wide::Wide;

static_assert(sizeof(::__kairo_ul<W>) == sizeof(W), "unflagged storage is the object's size");
static_assert(alignof(::__kairo_ul<W>) == alignof(W), "and its alignment");
static_assert(alignof(::__kairo_ulf<W>) == alignof(W), "flagged storage keeps the alignment");
static_assert(offsetof(::__kairo_ul<W>, v) == 0, "&x is the storage's address");
static_assert(offsetof(::__kairo_ulf<W>, s) == 0, "and flagged too");
static_assert(std::is_same_v<decltype(std::declval<::__kairo_ul<W>&>().v), W>, "decltype(x) is T");
static_assert(std::is_same_v<decltype(std::declval<::__kairo_ulf<W>&>().s.v), W>, "flagged too");
static_assert(std::is_aggregate_v<::__kairo_ul<W>>, "{init} copy-initializes the member");
static_assert(std::is_trivially_destructible_v<W> == false, "the object has a destructor to run");

int main() {
    std::printf("%lld %lld\n", static_cast<long long>(wide::probe(true)), static_cast<long long>(wide::probe(false)));
    return 0;
}
