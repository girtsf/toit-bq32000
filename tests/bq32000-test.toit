// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
Tests the driver against $FakeChip, a register-level model of the BQ32000.

The model stores writes verbatim and only imitates the chip behaviour the
  driver depends on: the key-protected special-function register, the
  oscillator-fail flag coming back while the crystal is dead, and the seconds
  register ticking in the middle of a burst read.
*/

import bq32000
import expect show *
import serial.device as serial
import serial.registers as serial

SECONDS ::= 0x00
MINUTES ::= 0x01
CENT-HOURS ::= 0x02
DAY ::= 0x03
DATE ::= 0x04
MONTH ::= 0x05
YEARS ::= 0x06
CAL-CFG1 ::= 0x07
TCH2 ::= 0x08
CFG2 ::= 0x09
SFKEY1 ::= 0x20
SFKEY2 ::= 0x21
SFR ::= 0x22

STOP ::= 0x80
OF ::= 0x80
CENT-EN ::= 0x80
CENT ::= 0x40
OUT ::= 0x80
FT ::= 0x40
S ::= 0x20

class FakeChip extends serial.Registers implements serial.Device:
  memory/ByteArray := ByteArray 0x23
  /** Every write as a [register, bytes] pair, oldest first. */
  writes/List := []
  /** Which of the two keys has been seen, so far, for the next SFR write. */
  unlock-stage_/int := 0
  /** How many more times clearing OF is answered by the chip re-raising it. */
  of-reraises/int := 0
  /** Whether the seconds register advances right after the next burst read. */
  tick-after-next-read/bool := false
  /** Whether the seconds register advances after every burst read. */
  tick-after-every-read/bool := false

  constructor:
    // Power-on state: OF set, STOP clear, configuration at the reset values.
    memory[MINUTES] = OF
    memory[CAL-CFG1] = 0x80
    memory[TCH2] = 0x90
    memory[CFG2] = 0xaa

  registers -> serial.Registers: return this
  read amount/int -> ByteArray: throw "UNUSED"
  write bytes/ByteArray -> none: throw "UNUSED"

  read-bytes register/int count/int -> ByteArray:
    result := memory[register..register + count].copy
    if register == SFKEY1 or register == SFKEY2: result.fill 0
    if register == SECONDS and count > 1:
      if tick-after-next-read or tick-after-every-read:
        tick-after-next-read = false
        memory[SECONDS]++
    return result

  write-bytes register/int data/ByteArray -> none:
    writes.add [register, data.copy]
    if register == SFKEY1 and data[0] == 0x5e:
      unlock-stage_ = 1
      return
    if register == SFKEY2 and data[0] == 0xc7:
      unlock-stage_ = unlock-stage_ == 1 ? 2 : 0
      return
    if register == SFR:
      if unlock-stage_ == 2: memory[SFR] = data[0]
      unlock-stage_ = 0
      return
    unlock-stage_ = 0
    memory.replace register data
    if register == MINUTES and (data[0] & OF) == 0 and of-reraises > 0:
      of-reraises--
      memory[MINUTES] |= OF

  /** Loads a time straight into the clock registers, bypassing the driver. */
  load --s --m --h --day --month --year --weekday=1 --cent=false -> none:
    memory[SECONDS] = (memory[SECONDS] & STOP) | (bcd s)
    memory[MINUTES] = (memory[MINUTES] & OF) | (bcd m)
    memory[CENT-HOURS] = CENT-EN | (cent ? CENT : 0) | (bcd h)
    memory[DAY] = weekday
    memory[DATE] = bcd day
    memory[MONTH] = bcd month
    memory[YEARS] = bcd year

  static bcd value/int -> int:
    return ((value / 10) << 4) | (value % 10)

/** A chip that has been set once, so that the time is valid. */
running-chip -> FakeChip:
  chip := FakeChip
  chip.memory[MINUTES] &= ~OF
  chip.load --s=0 --m=0 --h=0 --day=1 --month=1 --year=0
  return chip

main:
  test-address
  test-power-on-state
  test-set-time-encoding
  test-weekday
  test-round-trip
  test-century
  test-year-range
  test-set-time-refuses-stopped
  test-read-time-refuses
  test-read-retry
  test-stop-start
  test-oscillator-flag
  test-wait-until-running
  test-calibration
  test-square-wave
  test-trickle-charger

test-address:
  expect-equals 0x68 bq32000.I2C-ADDRESS

test-power-on-state:
  rtc := bq32000.Driver FakeChip
  expect rtc.is-running
  expect rtc.oscillator-failed
  expect-not rtc.is-time-valid
  expect-throw "BQ32000: time not valid": rtc.read-time

test-set-time-encoding:
  chip := FakeChip
  rtc := bq32000.Driver chip
  chip.writes.clear
  // A Friday.
  rtc.set-time (Time.utc --year=2026 --month=8 --day=28 --h=13 --m=45 --s=7)
  // One burst, nothing else.
  expect-equals 1 chip.writes.size
  expect-equals SECONDS chip.writes[0][0]
  expect-equals #[0x07, 0x45, CENT-EN | 0x13, 6, 0x28, 0x08, 0x26] chip.writes[0][1]
  // STOP and OF are both clear afterwards.
  expect rtc.is-time-valid

test-weekday:
  chip := FakeChip
  rtc := bq32000.Driver chip
  // The chip counts Sunday as 1, Toit counts Monday as 1.
  rtc.set-time (Time.utc --year=2026 --month=8 --day=30)  // Sunday.
  expect-equals 1 chip.memory[DAY]
  rtc.set-time (Time.utc --year=2026 --month=8 --day=31)  // Monday.
  expect-equals 2 chip.memory[DAY]
  rtc.set-time (Time.utc --year=2026 --month=9 --day=5)  // Saturday.
  expect-equals 7 chip.memory[DAY]

test-round-trip:
  rtc := bq32000.Driver FakeChip
  [
    Time.utc --year=2000 --month=1 --day=1,
    Time.utc --year=2026 --month=8 --day=28 --h=13 --m=45 --s=7,
    Time.utc --year=2099 --month=12 --day=31 --h=23 --m=59 --s=59,
    Time.utc --year=2100 --month=1 --day=1,
    Time.utc --year=2199 --month=12 --day=31 --h=23 --m=59 --s=59,
  ].do: | time/Time |
    rtc.set-time time
    expect-equals time rtc.read-time
  // Sub-second precision is dropped.
  rtc.set-time (Time.utc --year=2026 --month=1 --day=1 --s=1 --ms=999)
  expect-equals (Time.utc --year=2026 --month=1 --day=1 --s=1) rtc.read-time

test-century:
  chip := FakeChip
  rtc := bq32000.Driver chip
  rtc.set-time (Time.utc --year=2099 --month=12 --day=31 --h=23 --m=59 --s=59)
  expect-equals 0 (chip.memory[CENT-HOURS] & CENT)
  rtc.set-time (Time.utc --year=2100 --month=1 --day=1)
  expect-equals CENT (chip.memory[CENT-HOURS] & CENT)
  // What the chip does at the rollover: toggles CENT, wraps the year.
  chip.load --s=0 --m=0 --h=0 --day=1 --month=1 --year=0 --cent
  expect-equals 2100 rtc.read-time.utc.year
  chip.load --s=0 --m=0 --h=0 --day=1 --month=1 --year=99 --no-cent
  expect-equals 2099 rtc.read-time.utc.year

test-year-range:
  chip := FakeChip
  rtc := bq32000.Driver chip
  expect-throw "BQ32000: year 1999 out of range":
    rtc.set-time (Time.utc --year=1999 --month=12 --day=31 --h=23 --m=59 --s=59)
  expect-throw "BQ32000: year 2200 out of range":
    rtc.set-time (Time.utc --year=2200 --month=1 --day=1)
  expect-equals 0 chip.writes.size

test-set-time-refuses-stopped:
  chip := running-chip
  rtc := bq32000.Driver chip
  rtc.stop
  chip.writes.clear
  expect-throw "BQ32000: clock is stopped":
    rtc.set-time (Time.utc --year=2026 --month=1 --day=1)
  expect-equals 0 chip.writes.size

test-read-time-refuses:
  chip := running-chip
  rtc := bq32000.Driver chip
  expect-equals (Time.utc --year=2000 --month=1 --day=1) rtc.read-time
  chip.memory[SECONDS] |= STOP
  expect-throw "BQ32000: clock is stopped": rtc.read-time
  chip.memory[SECONDS] &= ~STOP
  chip.memory[MINUTES] |= OF
  expect-throw "BQ32000: time not valid": rtc.read-time

test-read-retry:
  chip := running-chip
  rtc := bq32000.Driver chip
  chip.load --s=58 --m=59 --h=23 --day=31 --month=12 --year=26
  // The seconds tick as the burst finishes; the re-read must catch it and the
  // returned time must be what the registers hold afterwards.
  chip.tick-after-next-read = true
  expect-equals (Time.utc --year=2026 --month=12 --day=31 --h=23 --m=59 --s=59) rtc.read-time
  // A clock that never holds still.
  chip.tick-after-every-read = true
  expect-throw "BQ32000: unstable clock read": rtc.read-time

test-stop-start:
  chip := running-chip
  rtc := bq32000.Driver chip
  chip.load --s=42 --m=0 --h=0 --day=1 --month=1 --year=0
  rtc.stop
  expect-not rtc.is-running
  expect-not rtc.is-time-valid
  // Only the STOP bit changes; the seconds are preserved.
  expect-equals (STOP | 0x42) chip.memory[SECONDS]
  rtc.start
  expect rtc.is-running
  expect-equals 0x42 chip.memory[SECONDS]

test-oscillator-flag:
  chip := running-chip
  rtc := bq32000.Driver chip
  chip.load --s=0 --m=37 --h=0 --day=1 --month=1 --year=0
  chip.memory[MINUTES] |= OF
  expect rtc.oscillator-failed
  expect-not rtc.is-time-valid
  rtc.clear-oscillator-failed
  expect-not rtc.oscillator-failed
  expect rtc.is-time-valid
  expect-equals 0x37 chip.memory[MINUTES]

test-wait-until-running:
  chip := running-chip
  rtc := bq32000.Driver chip
  expect-throw "BQ32000: clock is stopped":
    rtc.stop
    rtc.wait-until-running
  rtc.start

  // The crystal comes back after the flag has been cleared a few times.
  chip.memory[MINUTES] |= OF
  chip.of-reraises = 2
  rtc.wait-until-running
  expect-not rtc.oscillator-failed
  expect-equals 0 chip.of-reraises

  // A dead crystal.
  chip.of-reraises = 1000
  expect-throw "BQ32000: oscillator did not start":
    rtc.wait-until-running --timeout=(Duration --ms=250)
  expect rtc.oscillator-failed

test-calibration:
  chip := FakeChip
  rtc := bq32000.Driver chip
  // Leave OUT and FT alone.
  chip.memory[CAL-CFG1] = OUT | FT
  expect-equals 0 rtc.calibration
  rtc.set-calibration 31
  expect-equals (OUT | FT | S | 31) chip.memory[CAL-CFG1]
  expect-equals 31 rtc.calibration
  rtc.set-calibration -31
  expect-equals (OUT | FT | 31) chip.memory[CAL-CFG1]
  expect-equals -31 rtc.calibration
  rtc.set-calibration 0
  expect-equals 0 rtc.calibration
  [-31, -7, 0, 7, 31].do: | value/int |
    rtc.set-calibration value
    expect-equals value rtc.calibration
  expect-throw "BQ32000: calibration 32 out of range": rtc.set-calibration 32
  expect-throw "BQ32000: calibration -32 out of range": rtc.set-calibration -32

test-square-wave:
  chip := FakeChip
  rtc := bq32000.Driver chip
  expect-not rtc.square-wave-enabled
  expect-equals bq32000.SQUARE-WAVE-512HZ rtc.square-wave-frequency

  chip.writes.clear
  rtc.configure-square-wave --frequency=bq32000.SQUARE-WAVE-1HZ
  // Key 1, key 2, SFR, then the read-modify-write of CAL_CFG1.
  expect-equals 4 chip.writes.size
  expect-equals [SFKEY1, #[0x5e]] chip.writes[0]
  expect-equals [SFKEY2, #[0xc7]] chip.writes[1]
  expect-equals [SFR, #[0x01]] chip.writes[2]
  expect-equals CAL-CFG1 chip.writes[3][0]
  expect rtc.square-wave-enabled
  expect-equals bq32000.SQUARE-WAVE-1HZ rtc.square-wave-frequency
  expect-equals (OUT | FT) chip.memory[CAL-CFG1]

  rtc.configure-square-wave --frequency=bq32000.SQUARE-WAVE-512HZ
  expect-equals bq32000.SQUARE-WAVE-512HZ rtc.square-wave-frequency
  expect rtc.square-wave-enabled

  expect-throw "BQ32000: unsupported frequency 32768":
    rtc.configure-square-wave --frequency=32768

  rtc.disable-square-wave --high
  expect-not rtc.square-wave-enabled
  expect-equals OUT chip.memory[CAL-CFG1]
  rtc.disable-square-wave --no-high
  expect-not rtc.square-wave-enabled
  expect-equals 0 chip.memory[CAL-CFG1]

  // The keys are single-shot: a second SFR write without them is ignored.
  chip.memory[SFR] = 0
  chip.write-bytes SFR #[0x01]
  expect-equals bq32000.SQUARE-WAVE-512HZ rtc.square-wave-frequency

test-trickle-charger:
  chip := FakeChip
  rtc := bq32000.Driver chip
  expect-not rtc.trickle-charger-enabled

  rtc.configure-trickle-charger --enabled
  expect rtc.trickle-charger-enabled
  expect-not rtc.trickle-charger-bypass-diode
  // The reserved bits keep their power-on values.
  expect-equals 0xb0 chip.memory[TCH2]
  expect-equals 0xa5 chip.memory[CFG2]

  rtc.configure-trickle-charger --enabled --bypass-diode
  expect rtc.trickle-charger-enabled
  expect rtc.trickle-charger-bypass-diode
  expect-equals 0xe5 chip.memory[CFG2]

  rtc.configure-trickle-charger --no-enabled
  expect-not rtc.trickle-charger-enabled
  expect-not rtc.trickle-charger-bypass-diode
  expect-equals 0x90 chip.memory[TCH2]
  expect-equals 0xaa chip.memory[CFG2]

  // Half-configured states do not count as enabled.
  chip.memory[TCH2] |= 0x20
  expect-not rtc.trickle-charger-enabled
  chip.memory[TCH2] &= ~0x20
  chip.memory[CFG2] = 0xa5
  expect-not rtc.trickle-charger-enabled
