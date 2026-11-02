const PI: f64 = 3.141592653589793;
const SOLAR_MASS: f64 = 4.0 * PI * PI;
const DAYS_PER_YEAR: f64 = 365.24;

#[derive(Clone, Copy)]
struct Body { x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64 }

struct NBody { bodies: [Body; 5] }

impl NBody {
    fn new() -> Self {
        let mut bodies = [
            Body { x: 0.0, y: 0.0, z: 0.0, vx: 0.0, vy: 0.0, vz: 0.0, mass: SOLAR_MASS },
            Body { x: 4.84143144246472090e+00, y: -1.16032004402742839e+00, z: -1.03622044471123109e-01,
                   vx: 1.66007664274403694e-03 * DAYS_PER_YEAR, vy: 7.69901118419740425e-03 * DAYS_PER_YEAR,
                   vz: -6.90460016972063023e-05 * DAYS_PER_YEAR, mass: 9.54791938424326609e-04 * SOLAR_MASS },
            Body { x: 8.34336671824457987e+00, y: 4.12479856412430479e+00, z: -4.03523417114321381e-01,
                   vx: -2.76742510726862411e-03 * DAYS_PER_YEAR, vy: 4.99852801234917238e-03 * DAYS_PER_YEAR,
                   vz: 2.30417297573763929e-05 * DAYS_PER_YEAR, mass: 2.85885980666130812e-04 * SOLAR_MASS },
            Body { x: 1.28943695621391310e+01, y: -1.51111514016986312e+01, z: -2.23307578892655734e-01,
                   vx: 2.96460137564761618e-03 * DAYS_PER_YEAR, vy: 2.37847173959480950e-03 * DAYS_PER_YEAR,
                   vz: -2.96589568540237556e-05 * DAYS_PER_YEAR, mass: 4.36624404335156298e-05 * SOLAR_MASS },
            Body { x: 1.53796971148509165e+01, y: -2.59193146099879641e+01, z: 1.79258772950371181e-01,
                   vx: 2.68067772490389322e-03 * DAYS_PER_YEAR, vy: 1.62824170038242295e-03 * DAYS_PER_YEAR,
                   vz: -9.51592254519715870e-05 * DAYS_PER_YEAR, mass: 5.15138902046611451e-05 * SOLAR_MASS },
        ];
        let (px, py, pz) = bodies.iter().fold((0.0, 0.0, 0.0), |(x, y, z), b| (x + b.vx * b.mass, y + b.vy * b.mass, z + b.vz * b.mass));
        bodies[0].vx = -px / SOLAR_MASS;
        bodies[0].vy = -py / SOLAR_MASS;
        bodies[0].vz = -pz / SOLAR_MASS;
        NBody { bodies }
    }

    fn advance(&mut self, dt: f64) {
        let n = self.bodies.len();
        for i in 0..n {
            let (head, tail) = self.bodies.split_at_mut(i + 1);
            let a = &mut head[i];
            for b in tail.iter_mut() {
                let (dx, dy, dz) = (a.x - b.x, a.y - b.y, a.z - b.z);
                let d2 = dx * dx + dy * dy + dz * dz;
                let mag = dt / (d2 * d2.sqrt());
                let (mi, mj) = (a.mass * mag, b.mass * mag);
                a.vx -= dx * mj; a.vy -= dy * mj; a.vz -= dz * mj;
                b.vx += dx * mi; b.vy += dy * mi; b.vz += dz * mi;
            }
        }
        for b in self.bodies.iter_mut() {
            b.x += dt * b.vx; b.y += dt * b.vy; b.z += dt * b.vz;
        }
    }

    fn energy(&self) -> f64 {
        let mut e = 0.0;
        for (i, b) in self.bodies.iter().enumerate() {
            e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
            for c in &self.bodies[i + 1..] {
                let (dx, dy, dz) = (b.x - c.x, b.y - c.y, b.z - c.z);
                e -= b.mass * c.mass / (dx * dx + dy * dy + dz * dz).sqrt();
            }
        }
        e
    }
}

fn main() {
    let n: u64 = std::env::var("N").unwrap().parse().unwrap();
    let mut sys = NBody::new();
    println!("{:.9}", sys.energy());
    for _ in 0..n { sys.advance(0.01); }
    println!("{:.9}", sys.energy());
}
