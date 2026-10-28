// shapes2.k
import std::io::println

pub class Cat {
    pub var lives: i32
    pub fn Cat(self, lives: i32) { self.lives = lives }
    fn op delete(self) { println("  ~Cat") }
}

pub class Dog {
    pub var tricks: i32
    pub fn Dog(self, tricks: i32) { self.tricks = tricks }
    fn op delete(self) { println("  ~Dog") }
}