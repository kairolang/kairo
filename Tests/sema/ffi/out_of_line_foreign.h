struct S {
    void f(int&);
    void g(const int&);
    void h(int&&);
    void p(int*);
};
struct U { U(int); };
