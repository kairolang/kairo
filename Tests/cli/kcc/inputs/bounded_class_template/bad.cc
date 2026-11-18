#include "holder.k"
struct Plain { int z = 0; };
int main() {
    holder::Holder<Plain> h{Plain{1}};
    return 0;
}
