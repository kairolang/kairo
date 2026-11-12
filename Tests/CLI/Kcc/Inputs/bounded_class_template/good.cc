#include "holder.k"
int main() {
    holder::Holder<holder::Good> h{holder::Good(5)};
    return h.get();
}
