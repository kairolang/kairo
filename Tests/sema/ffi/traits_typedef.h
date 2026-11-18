// Corpus for traits_typedef.k, nested_inst.k, native_arg.k: a container
// whose size_type is a DEPENDENT member typedef reached through a traits
// class -- std::vector's size_type through allocator_traits, in miniature.
#pragma once

template <class A> struct traits { using size_type = typename A::st; };
struct alloc { using st = unsigned long; };

template <class T, class A = alloc> struct cont {
    using size_type = typename traits<A>::size_type;
    T* first;
    size_type n;
    size_type size() const;
    void push(const T&);
};

// Below here: qualified TYPE paths into shells (traits_typedef.k,
// dep_path.k). Appended, never inserted -- the tests above pin line:col in
// this file.

// A member typedef naming a NESTED CLASS of the instance, not a scalar.
template <class A> struct holder {
    struct node {
        typename A::st v;
        node* next;
        typename A::st get() const;
        struct tag { int id; int kind() const; };   // two levels: holder<A>::node::tag
    };
    using node_type = node;
    node first() const;                              // node reached as a RETURN type
};

// A member TEMPLATE of a class template: `outer<alloc>::inner<i32>::value`.
// (`value`, not `type`: `type` is a Kairo keyword and cannot follow `::`.)
template <class A> struct outer {
    template <class U> struct inner { using value = U; };
};

// clang cannot instantiate `bad<i32>`: `int::st` is ill-formed.
template <class A> struct bad { using size_type = typename A::st; };
