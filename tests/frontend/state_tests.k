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