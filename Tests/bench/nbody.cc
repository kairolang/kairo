#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>

constexpr double PI = 3.141592653589793;
constexpr double SOLAR_MASS = 4 * PI * PI;
constexpr double DAYS_PER_YEAR = 365.24;

struct Body { double x, y, z, vx, vy, vz, mass; };

class NBody {
    std::array<Body, 5> bodies;
public:
    NBody() : bodies{{
        {0, 0, 0, 0, 0, 0, SOLAR_MASS},
        {4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
         1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR,
         -6.90460016972063023e-05 * DAYS_PER_YEAR, 9.54791938424326609e-04 * SOLAR_MASS},
        {8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
         -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR,
         2.30417297573763929e-05 * DAYS_PER_YEAR, 2.85885980666130812e-04 * SOLAR_MASS},
        {1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
         2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR,
         -2.96589568540237556e-05 * DAYS_PER_YEAR, 4.36624404335156298e-05 * SOLAR_MASS},
        {1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
         2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR,
         -9.51592254519715870e-05 * DAYS_PER_YEAR, 5.15138902046611451e-05 * SOLAR_MASS},
    }} {
        double px = 0, py = 0, pz = 0;
        for (const auto& b : bodies) { px += b.vx * b.mass; py += b.vy * b.mass; pz += b.vz * b.mass; }
        bodies[0].vx = -px / SOLAR_MASS; bodies[0].vy = -py / SOLAR_MASS; bodies[0].vz = -pz / SOLAR_MASS;
    }
    void advance(double dt) {
        for (size_t i = 0; i < bodies.size(); ++i) {
            for (size_t j = i + 1; j < bodies.size(); ++j) {
                auto& a = bodies[i]; auto& b = bodies[j];
                double dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
                double d2 = dx * dx + dy * dy + dz * dz;
                double mag = dt / (d2 * std::sqrt(d2));
                double mi = a.mass * mag, mj = b.mass * mag;
                a.vx -= dx * mj; a.vy -= dy * mj; a.vz -= dz * mj;
                b.vx += dx * mi; b.vy += dy * mi; b.vz += dz * mi;
            }
        }
        for (auto& b : bodies) { b.x += dt * b.vx; b.y += dt * b.vy; b.z += dt * b.vz; }
    }
    double energy() const {
        double e = 0;
        for (size_t i = 0; i < bodies.size(); ++i) {
            const auto& b = bodies[i];
            e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
            for (size_t j = i + 1; j < bodies.size(); ++j) {
                double dx = b.x - bodies[j].x, dy = b.y - bodies[j].y, dz = b.z - bodies[j].z;
                e -= b.mass * bodies[j].mass / std::sqrt(dx * dx + dy * dy + dz * dz);
            }
        }
        return e;
    }
};

int main() {
    long n = std::atol(std::getenv("N"));
    NBody sys;
    std::printf("%.9f\n", sys.energy());
    for (long i = 0; i < n; ++i) sys.advance(0.01);
    std::printf("%.9f\n", sys.energy());
}
