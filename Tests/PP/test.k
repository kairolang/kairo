module std {
    macro eprint!(...t) {
        [(fn ()||  {
            var str = std::to_string(t);
            fprintf(stderr, "%s", str.raw());
        }())...]
    }
}

module foo {
    macro eprint!(...t) {
        var unique_id!(str) = std::to_string(t);
        fprintf(stderr, "%s", unique_id!(str).raw());
    }
}


eprint!("hello", 1, 2, 3, "world", 4, 5, 6)
std::eprint!("hello", 1, 2, 3, "world", 4, 5, 6)
foo::eprint!("hello", 1, 2, 3, "world", 4, 5, 6)