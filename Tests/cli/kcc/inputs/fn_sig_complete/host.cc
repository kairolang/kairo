#include "lib.k"
#include <cstring>

int main() {
    auto s = lib::name();
    auto p = lib::mk();
    return (int)std::strlen((const char*)s.c_str()) + p.x;
}
