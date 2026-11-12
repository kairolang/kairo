// A tuple of fields yielded from a `const self` generator is a tuple of
// the field types, not of their const-qualified forms: `(self.e.key,
// self.e.value)` converts to the declared `yield (K, V)`.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe

class <K, V> Entry {
    pub var key:   K
    pub var value: V

    fn Entry(self, const k: K, const v: V) {
        self.key   = k
        self.value = v
    }
}

class <K, V> Pairs {
    pub var e: Entry<K, V>

    fn Pairs(self, const k: K, const v: V) {
        self.e = Entry<K, V>(k, v)
    }

    pub fn op in (const self) -> yield (K, V) {
        var p = &self.e
        yield (p->key, p->value)
        yield (self.e.key, self.e.value)
    }
}

fn main() -> i32 {
    var p   = Pairs<i32, string>(3, "ab")
    var sum = 0
    for (k, v) in p {
        sum += k * 10 + (v.size() as i32)
    }

    return sum - 64
}
