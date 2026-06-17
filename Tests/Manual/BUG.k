@serializable(do_sum: true)
class Foo derives OldThing impl Printable {
    pub {
        var x: i32
        var y: i32 = 10
        fn get_x(self) -> i32 { return self.x }

        @packed
        @deprecated("use NewThing", since: 2)
        pub struct OldThing {
            var a: i32
            var b: u8
            pub {
                @packed
                @deprecated("use NewThing", since: 2)
                struct OldThing {
                    var a: i32
                    var b: u8

                    pub {
                        @packed
                        @deprecated("use NewThing", since: 2)
                        pub struct OldThing {
                            var a: i32
                            var b: u8
                            pub {
                                @packed
                                @deprecated("use NewThing", since: 2)
                                pub struct OldThing {
                                    var a: i32
                                    var b: u8
                                    pub {
                                        @packed
                                        @deprecated("use NewThing", since: 2)
                                        pub struct OldThing {
                                            var a: i32
                                            var b: u8
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

    }

    priv var secret: u64

    prot {
        var shared_state: *u8
        static fn helper() -> bool = true
    }

    fn <T impl Numeric> sum(self, items: [T]) -> T {
        var total: T = 0 as T
        for var i in items {
            total += i
        }
        return total
    }

    virtual fn describe(self) -> string = virtual

    fn op == (self, other: *Foo) -> bool {
        return self.x == other->x
    }
}
