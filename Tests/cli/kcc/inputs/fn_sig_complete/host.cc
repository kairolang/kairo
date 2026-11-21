#include "lib.k"
#include <cstring>

int main() {
    auto s = lib::name();
    auto p = lib::mk();
    return (int)s.size() + p.x;
}
