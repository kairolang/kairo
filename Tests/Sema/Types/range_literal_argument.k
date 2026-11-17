// What a range literal does not take from its parameter: a bound that does
// not fit the element type, a typed bound of another type, a range record of
// another shape, and an open range where nothing asks for one.

fn narrow(r: Range<u8>) -> u8 = r.end
fn span(r: Range<usize>) -> usize = r.end
fn start(r: RangeFrom<usize>) -> usize = r.begin

fn main() -> i32 {
    var a = narrow(0..300)
    var lo: i32 = 1
    var b = span(lo..3)
    var c = start(1..3)
    var d = 4..
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      :10:13: error [SC063E]: no matching overload for call to 'narrow'
// CHECK-NEXT: candidate not viable: cannot convert argument of type '<literal>' to parameter 'r' of type 'Range<u8>'
// CHECK:      :12:13: error [SC063E]: no matching overload for call to 'span'
// CHECK-NEXT: candidate not viable: cannot convert argument of type 'Range<i32>' to parameter 'r' of type 'Range<usize>'
// CHECK:      :13:13: error [SC063E]: no matching overload for call to 'start'
// CHECK-NEXT: candidate not viable: cannot convert argument of type '<literal>' to parameter 'r' of type 'RangeFrom<usize>'
// CHECK:      :14:13: error [SC085E]: an open range is only valid as a slice index or where a 'RangeFrom' or 'RangeTo' is expected; give it both bounds
// CHECK-NOT:  error
