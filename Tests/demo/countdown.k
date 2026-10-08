/// Countdown with joystick: up/down sets the time, left/right picks the LED color,
/// click starts / stops-and-resets. Beeps the last 3 seconds and plays sound.wav at zero.

ffi "c" import "sound.h"

// --- registers -------------------------------------------------------------

struct Reg { var addr: usize }

extend Reg {
    fn write(const self, v: u32) {
        unsafe { *(self.addr as unsafe *volatile u32) = v }
    }
    fn read(const self) -> u32 {
        unsafe { return *(self.addr as unsafe *volatile u32) }
    }
}

const RESETS_CLR       = Reg { addr: 0x4000F000 }
const RESET_DONE       = Reg { addr: 0x4000C008 }
const XOSC_CTRL        = Reg { addr: 0x40024000 }
const XOSC_STATUS      = Reg { addr: 0x40024004 }
const XOSC_STARTUP     = Reg { addr: 0x4002400C }
const CLK_REF_CTRL     = Reg { addr: 0x40008030 }
const CLK_REF_SELECTED = Reg { addr: 0x40008038 }
const CLK_ADC_CTRL     = Reg { addr: 0x40008060 }
const WATCHDOG_TICK    = Reg { addr: 0x4005802C }
const TIMER_RAWL       = Reg { addr: 0x40054028 }
const ADC_CS           = Reg { addr: 0x4004C000 }
const ADC_RESULT       = Reg { addr: 0x4004C004 }
const SIO_IN           = Reg { addr: 0xD0000004 }
const SIO_OUT_SET      = Reg { addr: 0xD0000014 }
const SIO_OUT_CLR      = Reg { addr: 0xD0000018 }
const SIO_OE_SET       = Reg { addr: 0xD0000024 }

// ADC (0), IO_BANK0 (5), PADS_BANK0 (8), PWM (14), TIMER (21)
const RESET_BITS: u32 = (1 as u32) | (1 as u32 << 5) | (1 as u32 << 8) | (1 as u32 << 14) | (1 as u32 << 21)
const FUNCSEL_PWM: u32 = 4
const FUNCSEL_SIO: u32 = 5
const PAD_PULLUP: u32 = 0x5A
const PAD_ANALOG: u32 = 0x80

const MUX_US: u32 = 2000
const SECOND_US: u32 = 1000000
const COLOR_US: u32 = 10000
const BLINK_US: u32 = 250000
const DEBOUNCE_US: u32 = 20000
const HOLD_DELAY_US: u32 = 600000
const SAMPLE_US: u32 = 125          // 8000 samples per second

const STICK_HIGH: u32 = 3000
const STICK_LOW: u32 = 1000
const STICK_DELAY_US: u32 = 400000
const STICK_REPEAT_US: u32 = 150000
const DEAD_ZONE: u32 = 300

fn gpio_ctrl(pin: u32) -> Reg = Reg { addr: 0x40014004 + 8 * (pin as usize) }
fn pad(pin: u32) -> Reg = Reg { addr: 0x4001C004 + 4 * (pin as usize) }

// PWM slice registers: CSR +0x00, DIV +0x04, CC +0x0C, TOP +0x10
fn pwm(slice: u32, offset: usize) -> Reg = Reg { addr: 0x40050000 + 0x14 * (slice as usize) + offset }

// --- clock, time, ADC ------------------------------------------------------

fn clock_init() {
    XOSC_CTRL.write(0xAA0)
    XOSC_STARTUP.write(47)
    XOSC_CTRL.write(0xAA0 | (0xFAB as u32 << 12))
    while (XOSC_STATUS.read() & (1 as u32 << 31)) == 0 { }

    CLK_REF_CTRL.write(2)
    while (CLK_REF_SELECTED.read() & (1 as u32 << 2)) == 0 { }

    CLK_ADC_CTRL.write((1 as u32 << 11) | (3 as u32 << 5))
    WATCHDOG_TICK.write((1 as u32 << 9) | 12)
}

fn now_us() -> u32 = TIMER_RAWL.read()

fn adc_init() {
    pad(26).write(PAD_ANALOG)
    pad(27).write(PAD_ANALOG)
    ADC_CS.write(1)
    while (ADC_CS.read() & (1 as u32 << 8)) == 0 { }
}

/// One 12-bit sample (0..4095) from ADC channel `ch` (0 = GP26, 1 = GP27).
fn adc_read(ch: u32) -> u32 {
    ADC_CS.write(1 | (ch << 12) | (1 as u32 << 2))
    while (ADC_CS.read() & (1 as u32 << 8)) == 0 { }
    return ADC_RESULT.read() & 0xFFF
}

// --- pin groups ------------------------------------------------------------

struct Pins { var mask: u32 }

extend Pins {
    static fn range(first: u32, count: u32) -> Pins = Pins { mask: ((1 as u32 << count) - 1) << first }

    fn high(const self) { SIO_OUT_SET.write(self.mask) }
    fn low(const self)  { SIO_OUT_CLR.write(self.mask) }

    fn make_outputs(const self) {
        for var p: u32 = 0; p < 30; ++p {
            if ((self.mask >> p) & 1) == 1 { gpio_ctrl(p).write(FUNCSEL_SIO) }
        }
        SIO_OE_SET.write(self.mask)
    }
}

// --- display ---------------------------------------------------------------

fn font(n: u32) -> u32 {
    var table: [u32; 10] = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]
    return table[n as usize]
}

class Display {
    var seg_first: u32
    var dig_first: u32

    fn Display(self, seg_first: u32, dig_first: u32) {
        self.seg_first = seg_first
        self.dig_first = dig_first
        self.off()
        self.segments().make_outputs()
        self.digits().make_outputs()
    }

    fn segments(const self) -> Pins = Pins::range(self.seg_first, 8)
    fn digits(const self) -> Pins = Pins::range(self.dig_first, 4)

    fn off(const self) {
        self.segments().high()
        self.digits().low()
    }

    fn show(const self, pattern: u32, d: u32) {
        self.off()
        var segs = Pins { mask: pattern << self.seg_first }
        var digit = Pins { mask: 1 as u32 << (self.dig_first + d) }
        segs.low()
        digit.high()
    }
}

// --- RGB LED via PWM -------------------------------------------------------

/// Common-cathode RGB LED on GP18 (R, slice 1A), GP19 (G, slice 1B), GP20 (B, slice 2A).
class RgbLed {
    pub var on: bool

    fn RgbLed(self) {
        for var s: u32 = 1; s <= 2; ++s {
            pwm(s, 0x0C).write(0)
            pwm(s, 0x10).write(255)
            pwm(s, 0x04).write(1 as u32 << 4)
            pwm(s, 0x00).write(1)
        }
        for var p: u32 = 18; p <= 20; ++p { gpio_ctrl(p).write(FUNCSEL_PWM) }
        self.on = true
    }

    fn rgb(const self, r: u32, g: u32, b: u32) {
        if !self.on {
            pwm(1, 0x0C).write(0)
            pwm(2, 0x0C).write(0)
            return
        }
        pwm(1, 0x0C).write((g << 16) | (r >> 2))   // red is ~4x brighter per mA: scale it down
        pwm(2, 0x0C).write(b)
    }

    /// Color wheel, `hue` in 0..767: red -> green -> blue -> red.
    fn hue(const self, hue: u32) {
        var f = hue & 0xFF
        var seg = hue >> 8
        if seg == 0 { self.rgb(255 - f, f, 0) }
        else if seg == 1 { self.rgb(0, 255 - f, f) }
        else { self.rgb(f, 0, 255 - f) }
    }
}

// --- buzzer: tones ---------------------------------------------------------

// Passive buzzer on GP22 = PWM slice 3, channel A. In tone mode the PWM clock is
// 12 MHz / 4 = 3 MHz, so a note's TOP = 3000000 / freq - 1 (precomputed).
const G6: u32 = 1912     // 1568 Hz
const C7: u32 = 1432     // 2093 Hz
const REST: u32 = 0

fn buzzer_init() {
    pwm(3, 0x0C).write(0)
    pwm(3, 0x04).write(4 as u32 << 4)    // DIV = 4.0
    pwm(3, 0x10).write(G6)
    pwm(3, 0x00).write(1)
    gpio_ctrl(22).write(FUNCSEL_PWM)
}

fn tone(top: u32) {
    if top == REST {
        pwm(3, 0x0C).write(0)
        return
    }
    pwm(3, 0x10).write(top)
    pwm(3, 0x0C).write(top >> 1)          // 50% duty square wave
}

enum Song derives u32 { Silent = 0, Click = 1, Beep = 2 }

fn song_len(s: Song) -> u32 {
    if s == Song::Silent { return 0 }
    return 1
}

fn song_note(s: Song, i: u32) -> u32 {
    if s == Song::Click { return C7 }
    return G6
}

fn song_ms(s: Song, i: u32) -> u32 {
    if s == Song::Click { return 15 }
    return 120
}

/// Plays one short song at a time without blocking: call poll() every loop.
class Player {
    var song: Song
    var index: u32
    var started: u32
    var length: u32

    fn Player(self) {
        self.song = Song::Silent
        self.index = 0
        self.started = 0
        self.length = 0
    }

    fn play(self, s: Song, now: u32) {
        self.song = s
        self.index = 0
        self.start_note(now)
    }

    fn start_note(self, now: u32) {
        if self.index >= song_len(self.song) {
            self.song = Song::Silent
            tone(REST)
            return
        }
        tone(song_note(self.song, self.index))
        self.started = now
        self.length = song_ms(self.song, self.index) * 1000
    }

    fn poll(self, now: u32) {
        if self.song == Song::Silent { return }
        if now - self.started >= self.length {
            self.index += 1
            self.start_note(now)
        }
    }
}

// --- buzzer: sampled audio -------------------------------------------------

/// Streams 8-bit unsigned 8 kHz samples (linked in from sound.wav) as PWM duty.
class WavPlayer {
    pub var playing: bool
    var index: u32
    var length: u32
    var next: u32

    fn WavPlayer(self) {
        self.playing = false
        self.index = 0
        self.length = sound_len()
        self.next = 0
    }

    fn start(self, now: u32) {
        pwm(3, 0x04).write(1 as u32 << 4)    // DIV = 1: 12 MHz / 256 = ~47 kHz carrier
        pwm(3, 0x10).write(255)
        self.index = 0
        self.next = now
        self.playing = true
    }

    fn stop(self) {
        self.playing = false
        pwm(3, 0x0C).write(0)
        pwm(3, 0x04).write(4 as u32 << 4)    // back to tone mode (DIV = 4)
    }

    fn poll(self, now: u32) {
        if !self.playing { return }
        if (now - self.next) >= 0x80000000 { return }   // not yet time for the next sample
        if self.index >= self.length {
            self.stop()
            return
        }

        // double the deviation from the midpoint, clamped to 0..255
        var s = sound_at(self.index) as u32
        var v: u32 = 128
        if s >= 128 {
            v = 128 + (s - 128) * 2
            if v > 255 { v = 255 }
        } else {
            var d = (128 - s) * 2
            if d >= 128 { v = 0 } else { v = 128 - d }
        }

        pwm(3, 0x0C).write(v)
        self.index += 1
        self.next += SAMPLE_US
    }
}

// --- input -----------------------------------------------------------------

enum Press derives u32 { Nothing = 0, Click = 1, Repeat = 2 }

class Button {
    var mask: u32
    var stable: bool
    var last_raw: bool
    var changed_at: u32
    var down_at: u32
    var held: bool

    fn Button(self, pin: u32, now: u32) {
        self.mask = 1 as u32 << pin
        pad(pin).write(PAD_PULLUP)
        gpio_ctrl(pin).write(FUNCSEL_SIO)
        self.stable = false
        self.last_raw = false
        self.changed_at = now
        self.down_at = now
        self.held = false
    }

    fn raw(const self) -> bool = (SIO_IN.read() & self.mask) == 0

    fn poll(self, now: u32) -> Press {
        var r = self.raw()
        if r != self.last_raw {
            self.last_raw = r
            self.changed_at = now
        }
        if r != self.stable && now - self.changed_at >= DEBOUNCE_US {
            self.stable = r
            if r {
                self.down_at = now
                self.held = false
                return Press::Nothing
            }
            if !self.held { return Press::Click }
            return Press::Nothing
        }
        if self.stable && !self.held && now - self.down_at >= HOLD_DELAY_US {
            self.held = true
            return Press::Repeat
        }
        return Press::Nothing
    }
}

enum Dir derives u32 { Center = 0, Up = 1, Down = 2 }

/// Up/down axis: one step on entering a direction, then auto-repeat.
class Stick {
    var channel: u32
    var dir: Dir
    var since: u32
    var next: u32

    fn Stick(self, channel: u32, now: u32) {
        self.channel = channel
        self.dir = Dir::Center
        self.since = now
        self.next = STICK_DELAY_US
    }

    fn poll(self, now: u32) -> Dir {
        var v = adc_read(self.channel)
        var d = Dir::Center
        if v > STICK_HIGH { d = Dir::Up } else if v < STICK_LOW { d = Dir::Down }

        if d != self.dir {
            self.dir = d
            self.since = now
            self.next = STICK_DELAY_US
            return d
        }
        if d != Dir::Center && now - self.since >= self.next {
            self.next += STICK_REPEAT_US
            return d
        }
        return Dir::Center
    }
}

/// Move `hue` (0..767) by the left/right deflection of ADC channel `ch`.
fn steer_hue(hue: u32, ch: u32) -> u32 {
    var x = adc_read(ch)
    if x > 2048 + DEAD_ZONE {
        var h = hue + ((x - 2048 - DEAD_ZONE) >> 7)
        if h >= 768 { h -= 768 }
        return h
    }
    if x < 2048 - DEAD_ZONE {
        var step = (2048 - DEAD_ZONE - x) >> 7
        if step > hue { return hue + 768 - step }
        return hue - step
    }
    return hue
}

// --- the countdown ---------------------------------------------------------

class Countdown {
    var m10: u32
    var m1: u32
    var s10: u32
    var s1: u32

    fn Countdown(self) {
        self.m10 = 0
        self.m1 = 0
        self.s10 = 3
        self.s1 = 0
    }

    fn is_zero(const self) -> bool {
        return self.m10 == 0 && self.m1 == 0 && self.s10 == 0 && self.s1 == 0
    }

    /// True during the final three seconds (3, 2, 1).
    fn final_seconds(const self) -> bool {
        return self.m10 == 0 && self.m1 == 0 && self.s10 == 0 && self.s1 > 0 && self.s1 <= 3
    }

    fn tick(self) -> bool {
        if self.is_zero() { return true }
        if self.s1 > 0 { self.s1 -= 1 } else {
            self.s1 = 9
            if self.s10 > 0 { self.s10 -= 1 } else {
                self.s10 = 5
                if self.m1 > 0 { self.m1 -= 1 } else { self.m1 = 9; self.m10 -= 1 }
            }
        }
        return self.is_zero()
    }

    fn add_ten(self) {
        if self.m1 == 9 && self.s10 == 5 { return }
        self.s1 = 0
        self.s10 += 1
        if self.s10 == 6 { self.s10 = 0; self.m1 += 1 }
    }

    fn sub_ten(self) {
        self.s1 = 0
        if self.s10 > 0 { self.s10 -= 1 }
        else if self.m1 > 0 { self.m1 -= 1; self.s10 = 5 }
    }

    fn digit(const self, i: u32) -> u32 {
        if i == 0 { return self.m10 }
        if i == 1 { return self.m1 }
        if i == 2 { return self.s10 }
        return self.s1
    }
}

enum Mode derives u32 { Setting = 0, Running = 1, Done = 2 }

// --- entry -----------------------------------------------------------------

ffi "c" fn Reset_Handler() -> ! {
    clock_init()
    RESETS_CLR.write(RESET_BITS)
    while (RESET_DONE.read() & RESET_BITS) != RESET_BITS { }
    adc_init()
    buzzer_init()

    var now = now_us()
    var display = Display(2, 10)
    var led = RgbLed()
    var player = Player()
    var wav = WavPlayer()
    var button = Button(15, now)
    var stick = Stick(0, now)           // ADC0 = GP26 = VRy

    var preset = Countdown()            // 00:30
    var count = preset
    var mode = Mode::Setting
    var hue: u32 = 0

    var last_mux = now
    var last_tick = now
    var last_color = now
    var last_blink = now
    var cur: u32 = 0

    loop {
        now = now_us()

        // display: one digit per MUX_US
        if now - last_mux >= MUX_US {
            last_mux = now
            cur = (cur + 1) & 3
            var pattern = font(count.digit(cur))
            if cur == 1 { pattern = pattern | 0x80 }
            display.show(pattern, cur)
        }

        // color: left/right steers the hue; blink while done
        if now - last_color >= COLOR_US {
            last_color = now
            hue = steer_hue(hue, 1)     // ADC1 = GP27 = VRx
            if mode == Mode::Done && now - last_blink >= BLINK_US {
                last_blink = now
                led.on = !led.on
            }
            led.hue(hue)
        }

        player.poll(now)
        wav.poll(now)

        // input
        var press = button.poll(now)
        var dir = stick.poll(now)

        if mode == Mode::Setting {
            if dir == Dir::Up {
                preset.add_ten()
                count = preset
                player.play(Song::Click, now)
            } else if dir == Dir::Down {
                preset.sub_ten()
                count = preset
                player.play(Song::Click, now)
            } else if press == Press::Click && !count.is_zero() {
                mode = Mode::Running
                last_tick = now
                player.play(Song::Click, now)
            }
        } else if press == Press::Click {
            mode = Mode::Setting
            count = preset
            led.on = true
            wav.stop()
            player.play(Song::Silent, now)
        }

        // countdown
        if mode == Mode::Running && now - last_tick >= SECOND_US {
            last_tick += SECOND_US
            if count.tick() {
                mode = Mode::Done
                last_blink = now
                wav.start(now)
            } else if count.final_seconds() {
                player.play(Song::Beep, now)
            }
        }
    }
}