import app::other::Derived
pub interface Look { fn own_v(self) -> i32 }
extend Derived impl Look {
    fn own_v(self) -> i32 { return self.own }
}
