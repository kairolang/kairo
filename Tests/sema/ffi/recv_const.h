// Corpus for parity/recv_const.k: a const / non-const overload pair on the
// receiver alone, a const-only method and a non-const-only one.
#pragma once

struct Buf {
    int*       data();
    const int* data() const;
    int        size() const;
    void       clear();
};
