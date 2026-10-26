// C++ host for kcc_include.k: a Kairo `fn` value seen from C++ through
// `#include "*.k"`. It is `::__kairo_fn<R(A...)>`, callable as is; a
// named function or a captureless lambda converts into one.
#include "kcc_include.k"

static int add_one(int v) { return v + 1; }

int main() {
    auto scale = ::kcc_include::make_scaler(3);
    ::kcc_include::Box<int> b(4);
    int r = b.map_with(add_one);
    int s = ::kcc_include::apply(+[](int v) -> int { return v * 10; }, 2);
    return (scale(5) == 15 && r == 5 && s == 20) ? 42 : 1;
}
