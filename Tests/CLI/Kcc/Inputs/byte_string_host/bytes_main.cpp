// bytes_main.cpp: a C++ host reading the slice a Kairo byte string is, and
// passing one of its own back.
#include "bytelit.k"
#include <iostream>

int main() {
    auto m = bytelit::magic();
    std::cout << "len " << m.len << ", first " << static_cast<int>(m.data[0])
              << ", last " << static_cast<int>(m.data[m.len - 1]) << "\n";
    std::cout << "static " << (bytelit::magic().data == m.data) << "\n";

    static const unsigned char mine[] = {1, 2, 3};
    decltype(m) view(mine, 3);
    std::cout << "total " << bytelit::total(view) << " " << bytelit::total(m) << "\n";
    return 0;
}
