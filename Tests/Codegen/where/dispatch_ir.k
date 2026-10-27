// dispatch_ir.k -- the C++ a `where` group becomes (WhereDispatchLowering):
// the public name is one function whose body tests the guards in
// declaration order and returns the matching candidate's result; each
// member's body is a candidate `__kairo_where_<name>_<k>`, k in source
// order, the fallback included. A method group's candidates are private
// members called through `this`; a fallback declared first is still the
// last call; guards proven to cover every value leave the last untested.

fn categorize(x: i32) -> i32 where x > 100 { return 2 }
fn categorize(x: i32) -> i32 where x > 0   { return 1 }
fn categorize(x: i32) -> i32               { return 0 }

fn first_fallback(x: i32) -> i32 { return 0 }
fn first_fallback(x: i32) -> i32 where x == 7 { return 7 }

fn sign(x: i32) -> i32 where x >= 0 { return 1 }
fn sign(x: i32) -> i32 where x < 0  { return -1 }

class Acc {
    pub var n: i32
    fn get(self, k: i32) -> i32 where k > self.n { return k }
    fn get(self, k: i32) -> i32 { return self.n }
}

fn main() -> i32 {
    var a = Acc{n: 1}
    return categorize(3) + first_fallback(7) + sign(-1) + a.get(4)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
//
// The class declares the dispatcher public and its candidates private.
// IR:      class Acc {
// IR-NEXT:   public: signed int n;
// IR-NEXT:   signed int get(signed int k);
// IR-NEXT:   private: signed int __kairo_where_get_0(signed int k);
// IR-NEXT:   signed int __kairo_where_get_1(signed int k);
//
// IR:      signed int categorize(signed int x) {
// IR-NEXT:     if(x> 100) {
// IR-NEXT:         return::dispatch_ir::__kairo_where_categorize_0(x);
// IR-NEXT:     }
// IR-NEXT:     if(x> 0) {
// IR-NEXT:         return::dispatch_ir::__kairo_where_categorize_1(x);
// IR-NEXT:     }
// IR-NEXT:     return::dispatch_ir::__kairo_where_categorize_2(x);
// IR-NEXT: }
// IR:      signed int __kairo_where_categorize_0(signed int x) {
// IR-NEXT:     return 2;
// IR:      signed int __kairo_where_categorize_1(signed int x) {
// IR-NEXT:     return 1;
// IR:      signed int __kairo_where_categorize_2(signed int x) {
// IR-NEXT:     return 0;
//
// The fallback is candidate 0 (declared first) and is called last.
// IR:      signed int first_fallback(signed int x) {
// IR-NEXT:     if(x == 7) {
// IR-NEXT:         return::dispatch_ir::__kairo_where_first_fallback_1(x);
// IR-NEXT:     }
// IR-NEXT:     return::dispatch_ir::__kairo_where_first_fallback_0(x);
// IR-NEXT: }
//
// IR:      signed int sign(signed int x) {
// IR-NEXT:     if(x >= 0) {
// IR-NEXT:         return::dispatch_ir::__kairo_where_sign_0(x);
// IR-NEXT:     }
// IR-NEXT:     return::dispatch_ir::__kairo_where_sign_1(x);
// IR-NEXT: }
//
// IR:      signed int Acc::get(signed int k) {
// IR-NEXT:     if(k> this->n) {
// IR-NEXT:         return this->__kairo_where_get_0(k);
// IR-NEXT:     }
// IR-NEXT:     return this->__kairo_where_get_1(k);
// IR-NEXT: }
// IR:      signed int Acc::__kairo_where_get_0(signed int k) {
// IR-NEXT:     return k;
// IR:      signed int Acc::__kairo_where_get_1(signed int k) {
// IR-NEXT:     return this->n;
