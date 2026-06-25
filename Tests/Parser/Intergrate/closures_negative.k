var bad_trailing_comma = fn ()|*x, | {  // expected-error: expected name or '*'
    return 0
}