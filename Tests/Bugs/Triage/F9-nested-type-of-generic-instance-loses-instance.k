// build: kairo F9-nested-type-of-generic-instance-loses-instance.k -o f20   (expect exit 7)
class <K> L {
    pub struct P {
        var k: K
    }

    pub fn L(self) { }

    pub fn make(self, k: K) -> P {
        return P { k: k }
    }
}

fn main() -> i32 {
    var l = L<i32>()
    var q: L<i32>::P = l.make(7)
    var n: i32 = q.k        // SC028E: q.k is typed 'K', not 'i32'
    return n
}
