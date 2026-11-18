// Corpus for operators.k: a member operator, and free operators in the
// type's namespace that only ADL can find.
#pragma once

namespace vm {

struct V {
    int x;
    V operator+(const V& o) const;
    V operator-() const;
};

V    operator*(int k, const V& v);
bool operator==(const V& a, const V& b);

}  // namespace vm

vm::V make_v();
