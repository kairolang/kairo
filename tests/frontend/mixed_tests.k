 /// literal expressions
 1;
 3.14;
 0x10;
 0b1010;
 0o123;
 1.2e3;
 1.2e-3;
 "hello";
 f"hello {name}";
 r"hello";
 b"hello";
 u"hello";
 true;
 false;
 null;
 'c';
 r'c';
 b'c';
 u'c';
 f'{v}';
 
 /// unary expressions
 -5;
 !true;
 ~0;
 ++x;
 --y;
 &z;
 *z;
 *z++;
 *z--;
 
 /// testing binary operators
 foo + 10;
 bar - 20;
 baz * 30;
 qux / 40;
 foo % 50;
 foo & 60;
 bar | 70;
 baz ^ 80;
 qux << 90;
 foo >> 100;
 bar = 1;
 baz += 2;
 qux -= 3;
 foo *= 4;
 bar /= 5;
 baz %= 6;
 qux &= 7;
 foo |= 8;
 bar ^= 9;
 
 /// variable references
 foo;
 bar;
 baz;
 qux;
 
 /// function calls with positional and named arguments
 parse_args(foo);
 parse_args(1, 2);
 parse_NArgs(x = 10, y = 20);
 parse_mixed_args(12, 34, y = 50);
 /* FIXME: add support for packing and unpacking arguments (e.g. ...args and args...) */
 
 /// object initialization (implicit object creation)
 initialize_obj({ // defined: `fn initialize_obj(obj: Point)`
     .x = 10,
     .y = 20
 });
 
 /// object initialization (explicit object creation)
 PointObject {
     x = 10,
     y = 20
 };
 
 /// map initialization - no trailing comma
 { 1: "one", 2: "two" };
 
 /// map initialization - with trailing comma
 { 1: "one", 2: "two", };
 
 /// set initialization - no trailing comma
 {1, 2, 3, 4, 5};
 
 /// set initialization - with trailing comma
 {1, 2, 3, 4, 5,};
 
 /// list initialization - no trailing comma
 [1, 2, 3, 4, 5];
 
 /// list initialization - with trailing comma
 [1, 2, 3, 4, 5,];
 
 /// tuple initialization - no trailing comma
 (1, 2, 3, 4, 5);
 
 /// tuple initialization - with trailing comma
 (1, 2, 3, 4, 5,);
 
 /// namespace and class method calls
 namespace::Class::method();
 foo::bar::method();
 object.property;
 instance.method();
 
 /// ternary and conditional expressions
 x ? 1 : 2;
 x == 0 ? "zero" : "non-zero";
 "hello" if x == 0 else "world";
 
 /// array and matrix access
 array[0];
 matrix[1][2];
 
 /// arithmetic expressions with parentheses
 (1 + 2) * 3;
 7 - (1 * 4);
 (foo - bar) * 2;
 
 /// chained method and property access
 namespace::Class::method().chain().property;
 namespace::Class::method().chain().property[0];
 namespace::Class::method().chain().property[xy + 1 if x == 0 else 2];
 
 /// type casting
 foo as int;
 bar as *float;
 bar as char*;
 // TODO: add support for all the types of casting
 // bas as const char*;
 
 /// arithmetic with different operator precedence
 foo * bar / baz;
 foo * (bar / baz);
 
 /// concurrency and control flow
 spawn  some_function;
 await  some_function;
 thread another_function;
 yield  result;
 delete foo;
 return 1;
 
 /// for loop iterator based
 for (i = 0; i < 10; i++) {
     print(i);
 }
 
 for i = 0; i < 10; i++ {
     print(i);
 }
 
 for ; i < 10; i++ {
     print(i);
 }
 
 for ;; i++ {
     print(i);
 }
 
 for ;; {
     print(i);
 }
 
 // for loop with range
 for element in collection {
     process(element);
 }
 
 for element: int in collection {
     process(element);
 }
 
 for element: int, f, y: float in collection {
     process(element);
 }
 
 /// switch case
 switch x {
     case 12 {
         break;
     }
     case 11:
     case 15:
         handle_case();
     default:
         handle_default();
     // default:
     //     handle_default();
     // SYNTAX ERROR:
 }
 
 /// while loop example
 while condition {
     print("looping...");
 }
 
 /// conditional statements with 'if', 'else', 'unless'
 if foo == 12 {
     print("foo is 12");
 } else if bar == 14 {
     print("bar is 14");
 } else unless foo == 10 {
     print("foo is not 10");
 } else {
     print("neither condition met");
 }
 
 unless foo == 10 {
     print("foo is not 10");
 }
 
 /// try-catch-finally block example
 try {
     execute_code();
 } catch e: SomeError {
     handle_error(e);
 } finally {
     finalize();
 }
 
 finally:
     finalize();

 panic RuntimeError("error message");
 
 /// advanced expressions and mixed control flow
 /// Ternary expressions with nested conditions
 (foo + bar) ? baz * 2 : qux / 3;
 (foo > bar) ? ("equal" if baz == qux else "not equal") : (foo == bar ? "foo and bar are equal" : "neither condition met");
 
 /// Ternary expressions with arithmetic and logical operators
 (foo == 0) ? (bar * 2 + 3) : (baz - qux / 2);
 x ? (y + 10) : (z == 20 ? z * 3 : z - 4);
 
 /// Mixed control flow with chained method calls
 object.method1().method2(foo ? "foo_value" : "bar_value").method3();
 
 /// Nested conditional expressions
 if foo == bar {
     return (baz > qux) ? "baz is greater" : "qux is greater";
 } else if (baz < 10) {
     return "baz is less than 10";
 } else unless (qux == 0) {
     return "qux is not zero";
 } else {
     return "default case";
 }
 
 /// Combining ternary expressions and loops
 for i = 0; i < 10; i++ {
     print((i % 2 == 0) ? "even" : "odd");
 }
 
 /// Complex arithmetic with type casting and precedence
 /* var logical_expr     = */ (foo && bar) || !(baz || qux);
 /* var complex_result   = */ ((foo * bar + 3) as float) / ((baz - qux) * 2);
 /* var mixed_operations = */ (foo * 2 + (bar - 1)) / ((baz % 5) * (qux / 4));
 
 /// Logical expressions with multiple conditions
 if foo && bar || baz {
     print("Complex logical condition met");
 } else unless foo || qux {
     print("Alternative condition met");
 }