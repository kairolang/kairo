// oracle for assoc_fill.k
#include <set>
#include <unordered_map>

void use_assoc() {
    std::set<int> s;
    std::unordered_map<int, int> m;
    s.insert(1);
    m[1] = 2;
    auto n = s.size() + m.size();
}
