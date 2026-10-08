/// Wiring test: each segment on digit 1, then "8." on each digit, then each RGB color.

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

const RESETS_CLR  = Reg { addr: 0x4000F000 }
const RESET_DONE  = Reg { addr: 0x4000C008 }
const SIO_OUT_SET = Reg { addr: 0xD0000014 }
const SIO_OUT_CLR = Reg { addr: 0xD0000018 }
const SIO_OE_SET  = Reg { addr: 0xD0000024 }

const IO_AND_PADS: u32 = (1 as u32 << 5) | (1 as u32 << 8)
const FUNCSEL_SIO: u32 = 5
const STEP: u32 = 400000

fn gpio_ctrl(pin: u32) -> Reg = Reg { addr: 0x40014004 + 8 * (pin as usize) }

fn delay(n: u32) {
    var count: u32 = 0
    unsafe {
        var c = &count as unsafe *volatile u32
        while *c < n { *c = *c + 1 }
    }
}

// --- pin groups ------------------------------------------------------------

/// A set of GPIOs driven together through SIO.
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

// --- devices ---------------------------------------------------------------

/// 4-digit common-anode 7-segment display: 8 consecutive segment pins
/// (A..G, DP; active low) and 4 consecutive digit pins (active high).
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

    /// Light `pattern` (bit 0 = A ... bit 7 = DP) on digit `d` (0 = leftmost).
    fn show(const self, pattern: u32, d: u32) {
        self.off()
        var segs = Pins { mask: pattern << self.seg_first }
        var digit = Pins { mask: 1 as u32 << (self.dig_first + d) }
        segs.low()
        digit.high()
    }
}

enum Color derives u32 { Red = 0, Green = 1, Blue = 2 }

/// Common-cathode RGB LED on 3 consecutive pins (R, G, B; active high).
class RgbLed {
    var first: u32

    fn RgbLed(self, first: u32) {
        self.first = first
        self.off()
        self.pins().make_outputs()
    }

    fn pins(const self) -> Pins = Pins::range(self.first, 3)
    fn off(const self) { self.pins().low() }

    fn set(const self, c: Color) {
        self.off()
        var p = Pins { mask: 1 as u32 << (self.first + c as u32) }
        p.high()
    }
}

// --- entry -----------------------------------------------------------------

ffi "c" fn Reset_Handler() -> ! {
    RESETS_CLR.write(IO_AND_PADS)
    while (RESET_DONE.read() & IO_AND_PADS) != IO_AND_PADS { }

    var display = Display(2, 10)
    var led = RgbLed(18)

    loop {
        for var s: u32 = 0; s < 8; ++s { display.show(1 as u32 << s, 0); delay(STEP) }
        for var d: u32 = 0; d < 4; ++d { display.show(0xFF, d); delay(STEP) }
        display.off()

        led.set(Color::Red);   delay(STEP)
        led.set(Color::Green); delay(STEP)
        led.set(Color::Blue);  delay(STEP)
        led.off()
    }
}