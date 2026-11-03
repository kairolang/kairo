// See nullable.k. unique_ptr links.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>

struct Node { int64_t val; std::unique_ptr<Node> next; };

static int64_t sum_list(const Node* n) { int64_t s = 0; for (; n; n = n->next.get()) s += n->val; return s; }
static const Node* find(const Node* n, int64_t want) { for (; n; n = n->next.get()) if (n->val == want) return n; return nullptr; }

int main() {
    int64_t n = std::atoll(std::getenv("N"));
    std::unique_ptr<Node> head;
    for (int64_t i = 0; i < n; ++i) head = std::make_unique<Node>(Node{(i * 2654435761) % 1000003, std::move(head)});
    int64_t total = 0, hits = 0;
    for (int64_t r = 0; r < 50; ++r) { total += sum_list(head.get()); if (find(head.get(), (r * 7919) % 1000003)) ++hits; }
    while (head) head = std::move(head->next);   // iterative teardown, no recursion
    std::printf("%lld %lld\n", (long long)total, (long long)hits);
}
