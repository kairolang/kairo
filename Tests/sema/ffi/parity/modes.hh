struct S {
    void f(int&);
    void g(const int&);
    void h(int&&);
    void b(int&);
    void b(const int&);
};
void free_f(int&);
void free_g(const int&);
void free_h(int&&);
