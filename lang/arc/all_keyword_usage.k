/* control flow */

macro _string! {
    to_string_some_special_name
}


class Foo {
    var a: u8;
    var b: u8;

    op as fn (self) -> *string {
        return "Foo";
    }

    op + (lhs: Foo, rhs: Foo) -> Foo {
        return Foo(lhs.a + rhs.a, lhs.b + rhs.b);
    }
}

class Foo {
    var a: u8;
    var b: u8;
    
    fn to_string_some_special_name()  -> string {

    }

    unsafe fn to_string_some_special_name()  -> string {
        return "Foo";
    }

    op [] fn (self, index: u32);
    unsafe op [] fn (self, index: u32);
}

fn main() {
    var foo = Foo();
    unsafe    foo[1];
    const     foo[1];
}

class CustomType {
    var ptr: *char;
    var len: usize;

    op as fn () -> PyObject* {
        /// ...
    }

    op delete fn () {
        /// ...
    }
}

var a = CustomType("hello world");

var b = a as PyObject*;



/// 9
switch "word" {
    /// 2
    case "hi":
        /// 1
        break;
    case "boi":
    case "word" {
        print("word");
    }
    /// 4
    default: print("this broken");
}

/// 7
if true:
    print("true");
else if false {
    print("false");
/// 6
} else {
    print("false");
}

/// 10
unless false {
    print("true");
} else unless 1 == 2 {
    print("false");
} else {
    print("false");
}

// LOOPS

/// 6
for i in 0:10 {
    break;
}

const for i in 0:10 {
    /// 2
    continue;
}


class Point {
    var static n_points = 0;

    static const fn get_n_points() -> int {
        return Point::n_points;
    }


    static fn add_point() {
        Point::n_points += 1;
    }
}


// HARD ERROR
inline const async panic fn div_by_0_hard_a(a: int, b: int = 0) -> int { // force try catch handling
    return a / b;
}

// HARD ERROR - Not forced to handle
fn div_by_0_hard_b(a: int, b: int = 0) -> int {
    return a / b;
}

// Error as value
fn div_by_0_soft(a: int, b: int = 0) -> Result<int, DivByZeroError> {
    if b == 0 {
        return DivByZeroError();
    }
    
    return a / b;
}

fn main() {
    // SOFT ERROR
    var const a = div_by_0_soft(10, 0);

    if a.is_err() {
        print("DivByZeroError");
    } else {
        var a = a.unwrap();
    }
    
    // HARD ERROR
    try {
        var b = div_by_0_hard_a(10, 0);
    } catch (err: DivByZeroError) {
        print("DivByZeroError");
    }

    // or

    var b = try div_by_0_hard_a(10, 0) catch (err: DivByZeroError) 10 catch (err: BaseError) 9;
    
    var c = div_by_0_hard_b(10, 0); // not forced to handle but you can if you want
}






/// 11
while true {
    break;
}

while false: break;


/* function && method */

/// 1
async fn background() -> string {
    /// 7
    return "yessir";
}

/// 2
define PI_MUL(x) {
    x * 3.143e-1
};

define PI_MUL(x): x * 3.143e-1;

/// 2
define FOO: 0;

fn add(a: int, b: int) -> int:
return (
    fn (a: int, b: int) -> int:
    return (
        fn (a: int, b: int) -> int:
        return (
            fn (a: int, b: int) -> int:
            return (
                fn (a: int, b: int) -> int:
                return (
                    fn (a: int, b: int) -> int:
                    return (
                        fn (a: int, b: int) -> u32:
                        return (a+b) as u32;
                    )(a, b) as int;
                )(a, b);
            )(a, b);
        )(a, b);
    )(a, b);
)(a, b);


var foo: tuple<u8, i8, u8, i8, u8> = (1, 2, 3, 4, 4, 5, 6)
var foo: (u8) = (6) // says error that not
var foo: u8 = 6

// optimize using avx
var mat: matrix<int,3,3> {
    1, 2, 3,
    2, 5, 6,
    3, 4, 7,
}

// dangling dildo pointer
var a: int* = &10; // invalid since you cant refrence a temp lvalue

// dyn and final cant be used together
var unsafe a = dyn!(10);

 a = "string";

 a.get<int>()

/// 3
fn add(a: int, b: int) -> int {
    return a + b;
}

fn add(a: int, b: int) -> int: return a + b;

fn add(a: int, b: int) -> int : a + b;

op + as fn add(lhs: u16, rhs: int) -> int: lhs + rhs;

u8 u16 u32 u128 i8 i16 i32 i128 f32 f64

f64 < 64 bytes
f64 > 64 bytes


var a:u32 = 10;
a.add(1)

in cpp

std::uint_32 add (std::uint_32 a, std::uint_32 b) {
    return a + b;
}

fn <T> Map(iter: T, fn (T) -> T)
    requires T impl Iterable {

}


module extend_syntax {
    class Foo {
        var a: u8;
        var b: u8;
    }
}

module idk_something_else {
    derives Foo {
        fn add(self, b: u8) -> u8 {
            return self + b;
        }
    }

    var inst = Foo();

    inst.add();


    try { errorable_fn_returns_result() } catch (err:Err) { };
}

//                             ffi "py" import os; ffi "py" import time; ffi "py" import
//                         math; fn main() { var A: float = 0.0; var B:
//                 float = 0.0; while true { var z: list<float> =  [0.0]*1760; let
//         b: list<string> = [" "]*1760; for (var j in range(0, 628, 7)){for(var i in
//     range(0, 628, 2)) { var c: float = math::      sin(i); var d:float=math::cos(j);let
// e: float = math::sin(A); var f: float                      =math::sin(j);var g:float=math::cos(A);
// var h: float = d + 2; var D:                                      float=1/( c * h * e+ f * g + 5);
// var l: float = math::                                                cos  ( i )  ; var m :  float
// = math::cos(B); var                                                  n : float = math :: sin(B);
// var t: float = c * h                                                 * g-f*e;var x: int=int(40 +                                               30 * D * (l * h * m - t * n));
//    var y: int = int(12 + 15                                        * D * ( l * h  * n + t * m));
//        var o: int = int(x + 80 * y);                             var N:int=int(8* ((f * e - c *
//            d * g) * m - c * d * e - f *                        g - l * d * n)); if 0 <= y < 22
//                 && 0 <= x < 80 && D > z[o] {             z[o] = D; if N > 0 { let
//                     charIndex: int = N; } else {       var charIndex: int = 0; }
//                     b[o] = ".,-~:;=!*#$@"[charIndex]; } } } os::system("cls");
//                         for (var k: int = 0; k < 1760; k++) { if k %
//                             80 == 0 { print('\n', end=''); } else
//                                 { print(b[k], end=''); }} A
//                                     += 0.04; B += 0.02;time
//                                        ::sleep(0.03);}}









import "get_fooled/foo.hlix" as foo;


pub import get_fooled::foo::{SomenamespaceInFOO} as thing;

