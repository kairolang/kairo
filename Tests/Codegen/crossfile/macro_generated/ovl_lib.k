pub struct Tag { }

pub class Shape {
    pub var kind: i32 = 1

    pub fn Shape(self) { }
}

pub class Sound {
    pub var kind: i32 = 2

    pub fn Sound(self) { }
}

pub class Probe {
    pub fn Probe(self) { }

    pub static fn want() -> i32 {
        return 1
    }
}

pub class Other {
    pub fn Other(self) { }

    pub static fn want() -> i32 {
        return 2
    }
}

// One invocation per family; each makes overloads of the same two names,
// one of them told apart from its raw twin by a defaulted parameter.
macro family!(Base_) {
    pub fn <T: type> is_a(p: *const Base_, tag: Tag = Tag()) -> bool {
        return p->kind == T::want()
    }

    pub fn <T: type> is_a(p: unsafe *const Base_) -> bool {
        return p != &null && p->kind == T::want()
    }

    pub fn <T: type> kind_of(p: *const Base_) -> i32 {
        return p->kind * 10 + T::want()
    }
}

family!(Shape)
family!(Sound)
