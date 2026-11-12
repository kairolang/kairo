#include "buf.k"

// C++ writes through the non-const operator[] (the place form, into w),
// reads through the const one (the read form, from r), and calls Keyed's
// read form by name: 5 + 20 + 7 + 103 = 135.
int main() {
    buf::Two t;
    t[0] = 5;
    const buf::Two& ct = t;
    int read = ct[1];
    buf::Keyed k;
    k[1] = 7;
    return t.w[0] + read + k.v[1] + k.__kairo_op_get(0);
}
