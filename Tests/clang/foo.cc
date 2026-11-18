namespace kairo {
    extern int add(int a, int b);
}

#include <iostream>

int main() {
    std::cout << "Hello, world! 2 + 3 = " << kairo::add(2, 3) << "\n";
    return 0;
}