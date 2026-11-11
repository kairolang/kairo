template <class T>
struct Box {
    T *p = nullptr;
    friend bool operator==(const Box &a, const Box &b) { return a.p == b.p; }
};
