/*==================== kairo code before processing ====================*/
ffi "c++" import "test.hpp";

/*==================== kairo code after processing =====================*/
#[NO_CODE_GEN]
ffi "c++" {
    module cxx_file_test_includes {
        // @cpp::include("concepts")
        // @cpp::include("coroutine")
        // @cpp::include("iostream")
        // @cpp::include("optional")
        // @cpp::include("ranges")
        // @cpp::include("string")
        // @cpp::include("vector")
        // the includes expand into the same format as after. (use the clang ast gen)
    }

    import cxx::primitives; // we define kairo bindings for the c++ primitives

    inline var globalVar: cxx::primitives::_int;

    // C-style struct
    struct CStyleStruct {
        var a: cxx::primitives::_int;
        var b: cxx::primitives::_double;
    }

    struct CPPStyleStruct {
        var a: cxx::primitives::_int;
        var b: cxx::primitives::_double;
        const fn toString() -> cxx_file_test_includes::std::string;
    }

    fn <T> add(a: T, b: T) -> T;

    interface <T> Arithmetic requires T is cxx::std::integral<T> | cxx::std::floating_point<T>;

    
    class <T> Calculator requires T is Arithmetic {
        pub fn add(a: T, b: T) -> T;
        pub fn subtract(a: T, b: T) -> T;
    }

    class MyClass {
        fn MyClass(self, val: cxx::primitives::_int);

        pub fn setValue(self, val: cxx::primitives::_int);
        pub const fn getValue(self) -> cxx::primitives::_int;

        priv var value: cxx::primitives::_int;
    }

    #[DEFINE_NEW_SYMBOL(fn createClosure(), prms=kairo::SYMBOL_TYPE::UKNOWN, ret=kairo::SYMBOL_TYPE::UKNOWN)]
    // we cant eval auto fucntions that have no return (unelss clang does that)

    struct Generator {
        struct promise_type {
            var current_value: cxx::primitives::_int;
            fn yield_value(cxx::primitives::_int value) -> cxx_file_test_includes::std::suspend_always;
            fn initial_suspend() -> cxx_file_test_includes::std::suspend_always;
            
            #[NO_EXCEPTION]
            fn final_suspend() -> cxx_file_test_includes::std::suspend_always;
            
            fn get_return_object() -> cxx_file_test_includes::Generator;
            fn return_void();
            fn unhandled_exception();
        }

        struct iterator {
            var coro: cxx_file_test_includes::std::coroutine_handle<cxx_file_test_includes::promise_type>;
            const op != fn ne(const other: &iterator);
            op ++ fn inc() -> &iterator;
            const op * fn mul() -> cxx::primitives::_int;
        }

        fn begin() -> iterator;
        fn end() -> iterator;

        var handle: cxx_file_test_includes::std::coroutine_handle<cxx_file_test_includes::promise_type>;
    }

    inline fn sequence(start: cxx::primitives::_int, step: cxx::primitives::_int) -> cxx_file_test_includes::Generator;
}
