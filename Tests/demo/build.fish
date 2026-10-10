#!/usr/bin/env fish
# Build and flash a .k program to a Raspberry Pi Pico. Run from anywhere.
# usage: fish Tests/demo/build.fish [name]    (builds Tests/demo/<name>.k, default: Tests/demo)
set -l D    (realpath (status dirname))
set -l B    $D/build
set -l ROOT /mnt/linux-dev/projects/kairo-lang
set -l K    $ROOT/build/x86_64-linux-gnu/debug/bin/kairo
set -l MNT  /run/media/$USER/RPI-RP2

set -l NAME demo
test (count $argv) -gt 0; and set NAME (string replace -r '\.k$' '' -- $argv[1])
set -l SRC $D/$NAME.k

function die; echo "error: $argv" >&2; exit 1; end

test -f $SRC; or die "no such file: $SRC"
mkdir -p $B

# one-time setup: boot2 + uf2conv
if not test -f $B/boot2.o
    if not test -f $B/boot2.bin
        curl -sL https://crates.io/api/v1/crates/rp2040-boot2/0.3.0/download -o $B/boot2.tar.gz; or die "boot2 download"
        tar xzf $B/boot2.tar.gz -C $B
        set -l f (ls $B/rp2040-boot2-0.3.0/bin/*w25q080*padded* 2>/dev/null | head -1)
        test -n "$f"; or die "no padded w25q080 blob; check: ls $B/rp2040-boot2-0.3.0/bin/"
        cp $f $B/boot2.bin
    end
    python3 $D/check_boot2.py $B/boot2.bin; or exit 1
    llvm-objcopy -I binary -O elf32-littlearm --rename-section .data=.boot2 $B/boot2.bin $B/boot2.o; or die "wrap boot2"
end
if not test -f $B/uf2conv.py
    curl -sL https://raw.githubusercontent.com/microsoft/uf2/master/utils/uf2conv.py -o $B/uf2conv.py
    curl -sL https://raw.githubusercontent.com/microsoft/uf2/master/utils/uf2families.json -o $B/uf2families.json
end

# build
$K --target thumbv6m-none-eabi -mcpu=cortex-m0plus -Os -ffunction-sections \
    --cache-dir=$B/cache -c -o $B/$NAME.o $SRC; or die "compile"

# no dynamic initializers allowed on bare metal
if llvm-objdump -h $B/$NAME.o | grep -q init_array
    die "$NAME.o has .init_array: a const was dynamically initialized"
end

# optional: convert Tests/demo/sound.wav into a linkable object
set -l extra
if test -f $D/sound.wav
    ffmpeg -loglevel error -y -i $D/sound.wav -ac 1 -ar 8000 \
        -af "highpass=f=700,lowpass=f=3500,acompressor=threshold=-30dB:ratio=12:attack=5:release=50:makeup=18dB,alimiter=limit=0.98" \
        -f u8 $B/sound.raw; or die "ffmpeg"
    pushd $B
    llvm-objcopy -I binary -O elf32-littlearm \
        --rename-section .data=.rodata.sound,alloc,load,readonly,data,contents \
        sound.raw sound.o; or die "wrap sound"
    popd
    llvm-objcopy --redefine-sym _binary_sound_raw_start=sound_start \
        --redefine-sym _binary_sound_raw_end=sound_end $B/sound.o; or die "rename sound symbols"
    set extra $B/sound.o
end

ld.lld -T $D/link.ld --gc-sections $B/boot2.o $B/$NAME.o $extra -o $B/$NAME.elf; or die "link"

# sanity: vector table = stack top, then odd (Thumb) reset address
set -l words (llvm-objdump -s -j .vectors $B/$NAME.elf | string match -r '^ 10000100 (\S+) (\S+)')
test "$words[2]" = 00200420; or die "bad stack top in vector table: $words[2]"
set -l rh (string sub -s 1 -l 2 $words[3])
test (math "0x$rh % 2") -eq 1; or die "reset vector is not a Thumb address: $words[3]"

llvm-objcopy -O binary $B/$NAME.elf $B/$NAME.bin; or die "objcopy"
python3 $B/uf2conv.py -b 0x10000000 -f 0xe48bff56 -c -o $B/$NAME.uf2 $B/$NAME.bin >/dev/null; or die "uf2"
echo "built $B/$NAME.uf2 ("(stat -c %s $B/$NAME.bin)" bytes)"

if test -d $MNT
    cp $B/$NAME.uf2 $MNT/; and echo "flashed"
else
    echo "Pico not mounted: hold BOOTSEL, plug in, mount, rerun"
end