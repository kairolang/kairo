#pragma once

struct Cp {
    int id = 0;
    static inline int copies = 0;
    static inline int moves = 0;
    Cp() = default;
    explicit Cp(int i) : id(i) {}
    Cp(const Cp &o) : id(o.id) { ++copies; }
    Cp(Cp &&o) noexcept : id(o.id) { ++moves; }
    Cp &operator=(const Cp &) = default;
    int which() const { return 1; }
    int which() { return 2; }
};

inline int cp_copies() { return Cp::copies; }
inline int cp_moves() { return Cp::moves; }

// Which overload ran: 1 `const T&`, 2 `T&&`.
struct Sink {
    int last = 0;
    void take(const Cp &) { last = 1; }
    void take(Cp &&) { last = 2; }
    void num(const int &) { last = 1; }
    void num(int &&) { last = 2; }
};
