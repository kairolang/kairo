// A type, a module or a function named where a value is required is one
// error at the name (SC094E): as a cast's operand, an arithmetic operand, a
// returned value, an initializer, an argument or an expression body. None
// reaches the typer's terminal-state check (`--type-check-only` is what the
// language server runs).

ffi "c++" import "vector"

class C { }
module m { }

fn h(x: i32) -> i32 = x

fn cast_type() -> i32 { return C as i32 }
fn add_module() -> i32 { return 1 + m }
fn cast_module() -> i32 { return m as i32 }
fn return_module() -> i32 { return m }
fn init_module() -> i32 {
    var x = m
    return 0
}
fn paren_module() -> i32 { return (m) }
fn arg_module() -> i32 = h(m)
fn std_overlay() -> i32 {
    cxx[0]
    return 0
}

class K {
    fn p(self) -> i32 = self.p
}

fn <T> g(x: T) -> T = g

struct <T> NS { var v: T }
extend <P> NS<P> {
    fn q(self) -> P = self.q
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: non_value_operands.k:14:32: error [SC094E]: 'C' is a type, not a value
// CHECK: non_value_operands.k:15:37: error [SC094E]: 'm' is a module, not a value
// CHECK: non_value_operands.k:16:34: error [SC094E]: 'm' is a module, not a value
// CHECK: non_value_operands.k:17:36: error [SC094E]: 'm' is a module, not a value
// CHECK: non_value_operands.k:19:13: error [SC094E]: 'm' is a module, not a value
// CHECK: non_value_operands.k:22:36: error [SC094E]: 'm' is a module, not a value
// CHECK: non_value_operands.k:23:28: error [SC094E]: 'm' is a module, not a value
// CHECK: non_value_operands.k:25:5: error [R053E]: 'cxx' names the C++ std overlay; write `cxx::std`
// CHECK: non_value_operands.k:30:25: error [SC094E]: 'self.p' is a function, not a value here; call it
// CHECK: non_value_operands.k:33:23: error [SC094E]: 'g' is a generic function; it is a value only as one instance, with every generic argument written
// CHECK: non_value_operands.k:37:23: error [SC094E]: 'self.q' is a function, not a value here; call it
// CHECK-NOT: {{error|warning|Internal Compiler Error}}
