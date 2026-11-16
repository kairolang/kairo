#include <string>
#include <vector>

inline int takes_str(const std::string &s) {
    return static_cast<int>(s.size()) + (s == " my kairo str" ? 100 : 0);
}

inline int takes_vec(const std::vector<int> &v) {
    int t = 0;
    for (int x : v) { t += x; }
    return t;
}
