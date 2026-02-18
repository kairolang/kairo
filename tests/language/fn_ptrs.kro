fn foo_point_to_me(a: const i32) -> bool {
    return true;
};

fn main() -> i32 {
    fn foo_this_is_an_other_fn(a: i32) -> bool { // normal function (no sharing of scope)
        return false;
    };

    var foo_this_is_an_fn = fn (a: i32) -> bool { // lambda function (sharing of scope)
        return false;
    };

    var foo_pte: fn (const i32) -> bool = foo_point_to_me; // function pointer (accepts a a lambda or a normal function)

    // intreating having the '{' in a nested string inside an fstring breaks it... example:
    // f"yes { "this is a normal :{ string " } should work right? "
    print(f"foo_this_is_an_fn = {":]" if foo_this_is_an_fn(12) else ":<[")}");
    print(f"foo_this_is_an_other_fn = {":]" if foo_this_is_an_other_fn(12) else ":<[")}");
    print(f"foo_pte = {":]" if foo_pte(12) else ":<[")}");
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
foo_this_is_an_fn = :<[
foo_this_is_an_other_fn = :<[
foo_pte = :]
// END TEST
*/
