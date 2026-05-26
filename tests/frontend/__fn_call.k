 parse_args(foo);
 parse_args(1, 2);
 parse_NArgs(x = 10, y = 20);
 parse_mixed_args(12, 34, y = 50);
 //foo<1>(bar);
 //((foo < 1) > bar); // how do we know if its this or a generic call?


 i^2 = -1
 i^2 = -i
 i = [ 0, 1,
      -1, 0]

 (real) vector spaces
 complex: V = { set of objects }
          Now choose two sections
          addition + scalar k

 axioms:
    | t                         |      (scalar)           k |
    |---------------------------|---------------------------|
    | u, v E V => u+v <- V      | ku <- V if u E V          |
    | u + v = v + u             | k(u + v) = ku + kv        |
    | u + (v + w) = (u + v) + w | (k + m)u = ku + mu        |
    |                           | k(mu) = (km)u             |
    | an object O, zero vector  | 1*u = u                   |
    |  0 + u = u + 0 = u        |                           |
    |                           |                           |
    | an object in V, -u        |                           |
    |     u + (-u) = 0          |                           |
    |---------------------------|---------------------------|

 if 2 set of 5 axioms are met. Say (V, +, k) becomes a vector space

 Ex: V = { single object of any kind }
       = { 0 (->) }

 This is the smallest vector space = zero vector space

 R^2 = { (x1, x2, ... xn), xi E R }

 u, v E R^n

 u + v = (x1 + y1, ... xn + yn) E R^n
 ku = (kx1, ... kn)
 10 axioms obvious

 new t, k

 V = { ret of all fucntions on (-inf, inf) }
 f, g E V ==> f(x), g(x)
 (f + g)(x) = f(x) + g(x)
          ==> f + g E V
 (kf)(x) = k(f(x)) E V

fn balance(str: string) {
    // str = "([]{}())" or something

    var stack: list::<char> = [];

    // so this: "([)]" would be unbalanced

    for c in str {
        if c == '(' || c == '[' || c == '{' {
            stack.push(c);
        } else if c == ')' {
            if stack.pop() != '(' {
                return false;
            }
        } else if c == ']' {
            if stack.pop() != '[' {
                return false;
            }
        } else if c == '}' {
            if stack.pop() != '{' {
                return false;
            }
        }
    }

    return stack.is_empty();
}