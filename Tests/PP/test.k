macro tag! {
    compile_note!("TAG")
    "debug"
}

macro repeat!(m) {
    compile_note!("REPEAT")
    m! m!
}

var result = repeat!(tag)


macro variadic!(...xs) {
    (call::f(xs))...
}

/*
template <typename... Args>
void eprint(Args &&...t) {
    if constexpr (sizeof...(t) == 0) {
        fwprintf(stderr, L"");
        return;
    }
    
    ((([&]() { // fixed so now thers no more UB with large strings
           auto str = std::to_string(t);
           fwprintf(stderr, L"%ls", str.raw());
       }())),
     ...);

     // no newlines
}
*/


macro eprint!(...t) {
    [(fn ()||  {
        var str = std::to_string(t);
        fprintf(stderr, "%s", str.raw());
    }())...]
}

eprint!("hello", 1, 2, 3, "world", 4, 5, 6)