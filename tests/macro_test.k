macro testing!(x) {
    assert_eq!(x, "macro_test");
};

macro testing! {
    assert_eq!(1, 1);
};

macro testing!(x, y) {
    assert_eq!(x, "macro_test");
    assert_eq!(y, "macro_test");
};

macro testing!;

// gammer: 'macro' 'testing' '!' ('(' (ident (',' ident)*)? ')')? ('{' ... '}')? ';'

testing! // fails since the macro is not called with the required arguments
testing!(macro_test) // passes since the macro is called with the required arguments
foo::testing!(macro_test) // fails since the macro does not exist in the module

// also add cli support to add macros at compile time with values as well
// --add-macro "testing!" "assert_eq!(1, 1);"

