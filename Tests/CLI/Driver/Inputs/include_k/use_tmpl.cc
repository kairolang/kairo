#include "tmpl.k"

int main() {
    tmpl::Box<long> b;
    b.v = 7;
    return tmpl::sq(3) + tmpl::first<short>(1, 2) + static_cast<int>(b.get()) + tmpl::use_box();
}
