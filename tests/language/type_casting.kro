class Base {
    pub var val: i32;
}

class Derived derives Base {
    var val: i32 = 42;

    fn Derived(self) {
        Base::val = 50; // shadowed val
        self.val = 42;  // val in Derived
    }

    fn get_val(self) -> i32 {
        return self.val;
    }

    fn op as (self) -> string {
        return "class: Derived";
    }
}

struct TempContainer {
    var vb: i32;
}

class ClassCasting {
    var val: i32;

    fn ClassCasting(self, val: i32) {
        self.val = val;
    }

    fn op as (self) -> TempContainer {
        return TempContainer {
            vb = self.val
        };
    }

    fn op delete (self) {
        print("destroying");
    }
}

fn takes_temp_container(tc: TempContainer) {
    print(f"{tc.vb}");
}

fn main() -> i32 {
    // Test 1: remove constness
    const const_val: i32 = 42;

    var non_const_val = const_val as i32;
    print(f"{non_const_val}");

    // Test 2: upcast
    var derived = Derived();
    var base = derived as Base;
    print(f"{base.val}");

    var d = Derived();

    var a: *Base = &d;
    var b1: *Derived = a as *Derived;

    print(f"{(*b1).get_val()}");

    var unsafe_cast: *i32 = 0x7FF000000000 as unsafe *i32;
    print(f"{unsafe_cast}");

    // missing tests for const cast
    // missing tests for downcast
    // idk what else to test

    var h: *i32,
        f: *i32,
        g: *i32 = 0xff1 as unsafe *i32;
        
    h = 0x7FF000000000 as unsafe *i32;
    f = h as unsafe *i32;

    print(f"f = {f}, h = {h}, g = {g}");

    var ic = ClassCasting(42);
    //takes_temp_container(ic as TempContainer); // without the cast this should work (since it's an implicit cast)

    return 0;
}

// what should template specialization look like?
// template <class T, typename... Es>
// class $question;

// template <class T, typename... Es> requires std::meta::is_class_v<T> && (std::meta::is_class_v<Es> && ...)
// class $question<T, Es...> : public T;

// template <class T, typename... Es> requires(std::meta::is_class_v<Es> && ...)
// class $question<T, Es...>;

/*

extend question<T, Es...> derives T requires <T: class, ...Es> if (meta::is_class_v::<T>  && (meta::is_class_v::<Es> && ...));
extend question<T, Es...>           requires <T: class, ...Es> if (meta::is_class_v::<Es> && ...);
extend question<T, Es...> with SomeInterface requires <T: class, ...Es>;


// ------------------ complex example of requires specialization ------------------
class AClass
  requires <T: class, ...Es> {
    ...
}

extend AClass::<T, Es...> with SomeInterface
  requires <T: class, ...Es> if (meta::is_class_v::<Es> && ...) {
    ...
}

extend AClass::<T, Es...> // without extending an interface
  requires <T: class, ...Es> if (meta::is_class_v::<T> && (meta::is_class_v::<Es> && ...)) {
    ...
}

// ------------------ simple example of requires specialization ------------------
class SomeOtherClass requires <T> {
    ...
}

extend SomeOtherClass::<T> with SomeInterface
  requires <T> {
    ...
}

extend SomeOtherClass::<i32> { // without extending an interface and a specific type
    ...
}

// ------------------ even simpler example of requires specialization ------------------
class AnotherClass {
    ...
}

extend AnotherClass { // this directly adds everything defined in the extension into the class itself
    ...
}


interface JsonIfy {
    fn to_json(self) -> string {};
}

class Book {
    var val: i32;

    fn Book(self, val: i32) {
        self.val = val;
    }

    fn op as (self) -> string {
        return "class: Book";
    }
}

extend Book with JsonIfy {
    fn to_json(self) -> &self {
        return f"val: {*&self.val}";
    }
}


*/

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
42
50
42
0x7ff000000000
f = 0x7ff000000000, h = 0x7ff000000000, g = 0xff1
destroying
// END TEST
*/