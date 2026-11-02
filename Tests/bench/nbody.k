import std::io::println
ffi "c" import "math.h"
ffi "c++" import "bench_env.h"

eval PI: f64 = 3.141592653589793
eval SOLAR_MASS: f64 = 4.0 * PI * PI
eval DAYS_PER_YEAR: f64 = 365.24

struct Body {
    var x: f64  var y: f64  var z: f64
    var vx: f64 var vy: f64 var vz: f64
    var mass: f64
}

class NBody {
    var bodies: [Body; 5]

    fn NBody(self) {
        self.bodies[0] = Body { x: 0.0, y: 0.0, z: 0.0, vx: 0.0, vy: 0.0, vz: 0.0, mass: SOLAR_MASS }
        self.bodies[1] = Body {
            x: 4.84143144246472090e+00, y: -1.16032004402742839e+00, z: -1.03622044471123109e-01,
            vx: 1.66007664274403694e-03 * DAYS_PER_YEAR, vy: 7.69901118419740425e-03 * DAYS_PER_YEAR,
            vz: -6.90460016972063023e-05 * DAYS_PER_YEAR, mass: 9.54791938424326609e-04 * SOLAR_MASS,
        }
        self.bodies[2] = Body {
            x: 8.34336671824457987e+00, y: 4.12479856412430479e+00, z: -4.03523417114321381e-01,
            vx: -2.76742510726862411e-03 * DAYS_PER_YEAR, vy: 4.99852801234917238e-03 * DAYS_PER_YEAR,
            vz: 2.30417297573763929e-05 * DAYS_PER_YEAR, mass: 2.85885980666130812e-04 * SOLAR_MASS,
        }
        self.bodies[3] = Body {
            x: 1.28943695621391310e+01, y: -1.51111514016986312e+01, z: -2.23307578892655734e-01,
            vx: 2.96460137564761618e-03 * DAYS_PER_YEAR, vy: 2.37847173959480950e-03 * DAYS_PER_YEAR,
            vz: -2.96589568540237556e-05 * DAYS_PER_YEAR, mass: 4.36624404335156298e-05 * SOLAR_MASS,
        }
        self.bodies[4] = Body {
            x: 1.53796971148509165e+01, y: -2.59193146099879641e+01, z: 1.79258772950371181e-01,
            vx: 2.68067772490389322e-03 * DAYS_PER_YEAR, vy: 1.62824170038242295e-03 * DAYS_PER_YEAR,
            vz: -9.51592254519715870e-05 * DAYS_PER_YEAR, mass: 5.15138902046611451e-05 * SOLAR_MASS,
        }
        var px = 0.0
        var py = 0.0
        var pz = 0.0
        for var i: usize = 0; i < 5; i += 1 {
            px += self.bodies[i].vx * self.bodies[i].mass
            py += self.bodies[i].vy * self.bodies[i].mass
            pz += self.bodies[i].vz * self.bodies[i].mass
        }
        self.bodies[0].vx = -px / SOLAR_MASS
        self.bodies[0].vy = -py / SOLAR_MASS
        self.bodies[0].vz = -pz / SOLAR_MASS
    }

    fn advance(self, dt: f64) {
        for var i: usize = 0; i < 5; i += 1 {
            for var j: usize = i + 1; j < 5; j += 1 {
                var dx = self.bodies[i].x - self.bodies[j].x
                var dy = self.bodies[i].y - self.bodies[j].y
                var dz = self.bodies[i].z - self.bodies[j].z
                var d2 = dx * dx + dy * dy + dz * dz
                var mag = dt / (d2 * sqrt(d2))
                var mi = self.bodies[i].mass * mag
                var mj = self.bodies[j].mass * mag
                self.bodies[i].vx -= dx * mj
                self.bodies[i].vy -= dy * mj
                self.bodies[i].vz -= dz * mj
                self.bodies[j].vx += dx * mi
                self.bodies[j].vy += dy * mi
                self.bodies[j].vz += dz * mi
            }
        }
        for var i: usize = 0; i < 5; i += 1 {
            self.bodies[i].x += dt * self.bodies[i].vx
            self.bodies[i].y += dt * self.bodies[i].vy
            self.bodies[i].z += dt * self.bodies[i].vz
        }
    }

    fn energy(const self) -> f64 {
        var e = 0.0
        for var i: usize = 0; i < 5; i += 1 {
            var b = self.bodies[i]
            e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz)
            for var j: usize = i + 1; j < 5; j += 1 {
                var dx = b.x - self.bodies[j].x
                var dy = b.y - self.bodies[j].y
                var dz = b.z - self.bodies[j].z
                e -= b.mass * self.bodies[j].mass / sqrt(dx * dx + dy * dy + dz * dz)
            }
        }
        return e
    }
}

fn main() -> i32 {
    var n = bench_n()
    var sys = NBody()
    println(f"{sys.energy()}")
    for var i: i64 = 0; i < n; i += 1 { sys.advance(0.01) }
    println(f"{sys.energy()}")
    return 0
}
