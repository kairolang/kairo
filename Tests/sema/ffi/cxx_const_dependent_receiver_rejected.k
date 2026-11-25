// A non-const method of a C++ class template called through a const
// object whose type depends on a Kairo type parameter: when every candidate
// the primary template declares is non-const, the call is SC063E at the
// generic definition, as on a concrete instance, instead of a C++ error in
// the full build.
ffi "c++" import "inputs/const_dependent_receiver.h"
ffi "c++" import "vector"

fn <T> clear_param(const v: cxx::std::vector<T>) {
    v.clear()
}

fn <T> push_param(const v: cxx::std::vector<T>, x: T) {
    v.push_back(x)
}

fn <T> push_local(x: T) {
    const w = cxx::std::vector<T>()
    w.push_back(x)
}

fn <T> put_bag(const b: Bag<T>, x: T) {
    b.put(x)
}

class <T> Holder {
    var v: cxx::std::vector<T>

    fn add(const self, x: T) {
        self.v.push_back(x)
    }
}

fn main() -> i32 {
    var v = cxx::std::vector<i32>()
    clear_param(v)
    push_param(v, 1)
    push_local(1)
    var b = Bag<i32>()
    put_bag(b, 1)
    var h = Holder<i32>()
    h.add(1)
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      cxx_const_dependent_receiver_rejected.k:10:5: error [SC063E]: no matching overload for call to 'clear'
// CHECK-NEXT: {{.*}}vector.h:{{[0-9]+:[0-9]+}}: note [I900N]: candidate not viable: 'clear' is not const; it cannot be called on a const object
// CHECK:      cxx_const_dependent_receiver_rejected.k:14:5: error [SC063E]: no matching overload for call to 'push_back'
// CHECK-NEXT: {{.*}}vector.h:{{[0-9]+:[0-9]+}}: note [I900N]: candidate not viable: 'push_back' is not const; it cannot be called on a const object
// CHECK:      cxx_const_dependent_receiver_rejected.k:19:5: error [SC063E]: no matching overload for call to 'push_back'
// CHECK-NEXT: {{.*}}vector.h:{{[0-9]+:[0-9]+}}: note [I900N]: candidate not viable: 'push_back' is not const; it cannot be called on a const object
// CHECK:      cxx_const_dependent_receiver_rejected.k:23:5: error [SC063E]: no matching overload for call to 'put'
// CHECK-NEXT: const_dependent_receiver.h:6:5: note [I900N]: candidate not viable: 'put' is not const; it cannot be called on a const object
// CHECK:      cxx_const_dependent_receiver_rejected.k:30:9: error [SC063E]: no matching overload for call to 'push_back'
// CHECK-NEXT: {{.*}}vector.h:{{[0-9]+:[0-9]+}}: note [I900N]: candidate not viable: 'push_back' is not const; it cannot be called on a const object
// CHECK-NOT:  error
