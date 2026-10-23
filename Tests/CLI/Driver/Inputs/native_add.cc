// C++ half of the native-inputs fixture. <vector> proves the libc++ headers
// and runtime reach a native input; extern "C" is what the C half links to.
#include <vector>

extern "C" int add(int a, int b) {
    std::vector<int> v{a, b};
    int s = 0;
    for (int x : v) { s += x; }
    return s;
}
