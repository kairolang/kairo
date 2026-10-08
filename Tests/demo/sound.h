#pragma once

typedef __UINT8_TYPE__  sound_u8;
typedef __UINT32_TYPE__ sound_u32;

extern const sound_u8 sound_start[];
extern const sound_u8 sound_end[];

static inline sound_u32 sound_len(void) { return (sound_u32)(sound_end - sound_start); }
static inline sound_u8 sound_at(sound_u32 i) { return sound_start[i]; }