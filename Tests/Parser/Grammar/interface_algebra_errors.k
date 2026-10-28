// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s
//
// The forms a `derives` clause rejects, each in its own file position so the
// recovery of one does not swallow the next.
// CHECK: interface_algebra_errors.k:20:18: error [S001E]: an interface derives from other interfaces; 'impl' is for a type that conforms to one
// CHECK-NEXT: fix-it:{{.*}}:{20:18-20:22}:"derives"
// CHECK: interface_algebra_errors.k:22:25: error [S001E]: '^' (symmetric difference) is not an interface operator; use '+', '-' or '&'
// CHECK: interface_algebra_errors.k:24:26: error [S001E]: '|' is not an interface operator; union is '+'
// CHECK-NEXT: fix-it:{{.*}}:{24:26-24:27}:"+"
// CHECK: interface_algebra_errors.k:26:28: error [S001E]: a 'derives' clause composes whole interfaces; a single member cannot be removed. Declare an interface with that member and subtract it
// CHECK: interface_algebra_errors.k:28:25: error [S001E]: only '+' (union), '-' (difference) and '&' (intersection) compose interfaces
//
//
//
//
//
interface X { fn a(self) }
interface Y { fn b(self) }

interface ImplKw impl X { }

interface Xor derives X ^ Y { }

interface Pipe derives X | Y { }

interface Drop derives X - fn a { }

interface Mul derives X * Y { }
