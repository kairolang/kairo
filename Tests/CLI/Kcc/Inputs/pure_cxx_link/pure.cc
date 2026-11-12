#include <cstdio>
#include <cstdlib>
#include <vector>
int main() {
    std::vector<int> v{1, 2, 3};
    int *p = static_cast<int *>(std::malloc(sizeof(int)));
    *p = static_cast<int>(v.size());
    int r = *p;
    std::free(p);
    return r;
}
