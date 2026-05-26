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
 