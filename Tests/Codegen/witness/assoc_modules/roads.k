import graph::Graph
pub struct City { pub var id: i32 }
pub class Road impl Graph {
    type Node = i64
    pub fn Road(self) { }
    pub fn first(const self) -> i64 { return 20 }
    pub fn weight(const self, n: i64) -> i32 { return (n + 1) as i32 }
}
pub class Map {
    type Node = City
    pub fn Map(self) { }
    pub fn first(const self) -> City { return City { id: 7 } }
    pub fn weight(const self, n: City) -> i32 { return n.id * 2 }
}
