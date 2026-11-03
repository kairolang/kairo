#include "words.k"

// Calls the inferred `const string&` functions from C++, directly and
// through a pointer taken against the header's signature.
int main() {
    auto s = words::make(5);
    auto pm = &words::measure;
    words::Bag b;
    b.add(s);
    b.add(s);
    return static_cast<int>(words::measure(s) + pm(s) + words::grow(s) + b.total + s.length());
}
