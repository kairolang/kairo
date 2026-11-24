// A cast from a `T?` not proven non-null: to a nullable target it converts
// the value and keeps null, so only a conversion `T as U?` has not is an
// error, and it names the nullable as written. To a non-nullable target the
// value's `op as` is no conversion of the nullable: SC027E says the value
// converts and the read may be null.
// One diagnostic per `bad_*`, none per `ok_*`.

class Temp {
    var v: i32
    fn op as(self) -> i64 { return self.v }
}

class Box {
    var v: i32
}

fn bad_value_op_as_string(x: i32?) -> string {
    return x as string
}

fn bad_value_op_as_member(t: Temp?) -> i64 {
    return t as i64
}

fn bad_lift_no_conversion(x: i64?) -> Box? {
    return x as Box?
}

fn bad_lift_bool(x: bool?) -> Box? {
    return x as Box?
}

fn ok_proven_op_as(x: i32?) -> string {
    if !x? { return "" }
    return x as string
}

fn ok_lift(x: i32?) -> string? {
    return x as string?
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: {{.*}}:18:12: error [SC027E]: no conversion from 'i32?' to 'string': 'i32' converts, but this 'i32?' may be null
// DIAG-NEXT: {{.*}}:18:12: note [I900N]: test it for null first ('if x?' proves it), supply a value with '??', or cast to 'string?' to keep null
// DIAG-NEXT: {{.*}}:22:12: error [SC027E]: no conversion from 'Temp?' to 'i64': 'Temp' converts, but this 'Temp?' may be null
// DIAG-NEXT: {{.*}}:22:12: note [I900N]: test it for null first ('if x?' proves it), supply a value with '??', or cast to 'i64?' to keep null
// DIAG-NEXT: {{.*}}:26:12: error [SC027E]: no conversion from 'i64?' to 'Box?'
// DIAG-NEXT: {{.*}}:30:12: error [SC027E]: no conversion from 'bool?' to 'Box?'
// DIAG-NOT: {{error|warning}}
