#include <cstdio>
#include <cstdlib>
#include <memory>

struct Node {
    std::unique_ptr<Node> left, right;
    int check() const { return left ? 1 + left->check() + right->check() : 1; }
};

std::unique_ptr<Node> bottom_up(int depth) {
    auto n = std::make_unique<Node>();
    if (depth > 0) { n->left = bottom_up(depth - 1); n->right = bottom_up(depth - 1); }
    return n;
}

int main() {
    int n = std::atoi(std::getenv("N"));
    int max_depth = n > 6 ? n : 6;
    {
        auto stretch = bottom_up(max_depth + 1);
        std::printf("stretch tree of depth %d\t check: %d\n", max_depth + 1, stretch->check());
    }
    auto long_lived = bottom_up(max_depth);
    for (int d = 4; d <= max_depth; d += 2) {
        int iters = 1 << (max_depth - d + 4);
        int check = 0;
        for (int i = 0; i < iters; ++i) check += bottom_up(d)->check();
        std::printf("%d\t trees of depth %d\t check: %d\n", iters, d, check);
    }
    std::printf("long lived tree of depth %d\t check: %d\n", max_depth, long_lived->check());
}
