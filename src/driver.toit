// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import serial.device as serial
import serial.registers as serial

import .registers as reg

/**
Driver for the Texas Instruments BQ32000 I2C real-time clock.

The BQ32000 keeps time in binary-coded decimal in a bank of clock registers,
  and it tracks the century in a single toggling bit of the hours register. The
  driver hides both details and works with $Time values.

The chip has a fixed I2C address, $I2C-ADDRESS, and runs at up to 400kHz.

# Examples
```
import bq32000
import i2c

main:
  bus := i2c.Bus --sda=21 --scl=22
  device := bus.device bq32000.I2C-ADDRESS
  rtc := bq32000.Driver device
  if not rtc.is-time-valid:
    if not rtc.is-running:
      rtc.start
      rtc.wait-until-running
    rtc.set-time Time.now
  print rtc.read-time
```
*/

/** The I2C address of the BQ32000. It is not configurable. */
I2C-ADDRESS ::= 0x68

/** A 1Hz square wave on the IRQ pin. See $Driver.configure-square-wave. */
SQUARE-WAVE-1HZ ::= 1
/** A 512Hz square wave on the IRQ pin. See $Driver.configure-square-wave. */
SQUARE-WAVE-512HZ ::= 512

/**
The first year the driver can represent.

The chip stores only two digits of the year and one century bit, so the driver
  covers the 200 years starting here. See $Driver.set-time.
*/
CENTURY-BASE ::= 2000

/**
Driver for the BQ32000 real-time clock.

The driver holds no resources of its own. It does not own the device it is
  given, and closing that device is the caller's job.
*/
class Driver:
  /** How often a clock read is retried before it is declared unstable. */
  static READ-ATTEMPTS_ ::= 5
  /** The default timeout for $wait-until-running. */
  static DEFAULT-WAIT-TIMEOUT ::= Duration --s=3
  /** How long $wait-until-running gives the chip to re-raise the fail flag. */
  static WAIT-POLL-MS_ ::= 100

  registers_/serial.Registers

  /** Constructs a driver for the BQ32000 on the given $device. */
  constructor device/serial.Device:
    registers_ = device.registers

  /**
  Reads the current time from the clock.

  The BQ32000 has no notion of a time zone; the returned $Time is built from
    the register contents as if they were UTC.

  The clock registers are not latched during a multi-byte read, so the read is
    repeated if the seconds field advances while it is in progress.

  # Errors
  Throws if the clock is stopped, or if the oscillator has failed since the flag
    was last cleared, which is the case on a chip that has never been set. See
    $oscillator-failed and $is-running.

  The chip needs more than a second after power-up, or after leaving backup
    mode, before the registers hold the current time rather than the time at
    which it entered backup mode. Reading earlier yields a stale value that
    looks perfectly valid.
  */
  read-time -> Time:
    bytes := read-clock_
    if (bytes[0] & reg.SECONDS-STOP) != 0: throw "BQ32000: clock is stopped"
    if (bytes[1] & reg.MINUTES-OF) != 0: throw "BQ32000: time not valid"
    year := CENTURY-BASE + (from-bcd_ bytes[6])
    if (bytes[2] & reg.CENT-HOURS-CENT) != 0: year += 100
    return Time.utc
        --year=year
        --month=(from-bcd_ (bytes[5] & reg.MONTH-VALUE))
        --day=(from-bcd_ (bytes[4] & reg.DATE-VALUE))
        --h=(from-bcd_ (bytes[2] & reg.CENT-HOURS-VALUE))
        --m=(from-bcd_ (bytes[1] & reg.MINUTES-VALUE))
        --s=(from-bcd_ (bytes[0] & reg.SECONDS-VALUE))

  /**
  Sets the clock to the given $time.

  Clears the oscillator-fail flag as a side effect, so a call to this method
    makes $read-time succeed again. Never blocks: it is a handful of I2C
    transactions and nothing else.

  The clock must be running. A halted clock does not take a written time
    properly, and restarting it costs about half a second, so rather than hide
    that delay this refuses. To recover a clock halted with $stop:

  ```
  rtc.start
  rtc.wait-until-running
  rtc.set-time Time.now
  ```

  The $time is written as its UTC representation. Its year must lie within the
    200 years starting at $CENTURY-BASE. The century bit is written to say
    which of the two halves the year is in, and the chip toggles it when the
    two-digit year wraps, so the clock keeps reading back correctly across the
    turn of the century.

  The weekday register is written with the chip's convention, 1 for Sunday
    through 7 for Saturday. The chip advances it daily but never derives it
    from the date, and $read-time does not use it, so the value only matters
    to other software reading the same chip.

  # Errors
  It is an error to pass a $time outside the representable range.

  Throws if the clock is stopped. See $wait-until-running.
  */
  set-time time/Time -> none:
    info := time.utc
    offset := info.year - CENTURY-BASE
    if offset < 0 or offset >= 200:
      throw "BQ32000: year $info.year out of range"
    hours := to-bcd_ info.h
    hours |= reg.CENT-HOURS-CENT-EN
    if offset >= 100: hours |= reg.CENT-HOURS-CENT
    bytes := ByteArray 7
    bytes[0] = to-bcd_ info.s  // Clears STOP.
    bytes[1] = to-bcd_ info.m  // Clears OF.
    bytes[2] = hours
    bytes[3] = info.weekday % 7 + 1  // Toit has Monday=1, the chip Sunday=1.
    bytes[4] = to-bcd_ info.day
    bytes[5] = to-bcd_ info.month
    bytes[6] = to-bcd_ (info.year % 100)

    // Writing the time to a halted clock does not work: the burst lands on
    // every field except seconds, which keeps its old value. Rather than paper
    // over that with a hidden restart and an unpredictable delay, refuse.
    if not is-running:
      throw "BQ32000: clock is stopped"

    registers_.write-bytes reg.SECONDS bytes

  /**
  Whether the clock holds a time that can be read.

  True when the clock is running and the oscillator-fail flag is clear, which is
    exactly what $read-time requires, so this is the cheap way to ask whether a
    read will succeed. Both bits come from one I2C transaction.

  A true result does not promise the time is *right*. It says the chip has been
    keeping time since the flag was last cleared; it cannot know whether the
    time written back then was correct, and $wait-until-running clears the flag
    on a clock that is knowingly behind.
  */
  is-time-valid -> bool:
    status := registers_.read-bytes reg.SECONDS 2
    return (status[0] & reg.SECONDS-STOP) == 0 and (status[1] & reg.MINUTES-OF) == 0

  /**
  Whether the oscillator is released.

  Returns the inverse of the STOP bit, so it goes true the moment $start writes
    the register. That is not the same as the crystal actually oscillating,
    which takes about half a second longer; $wait-until-running waits for that.
  */
  is-running -> bool:
    return ((registers_.read-u8 reg.SECONDS) & reg.SECONDS-STOP) == 0

  /**
  Starts the oscillator.

  Clears the STOP bit. The clock resumes from the value it was halted at, which
    means it is behind by the time it spent stopped.

  Returns as soon as the bit is written. The crystal needs roughly half a
    second to come back, and the chip keeps re-raising the oscillator-fail flag
    for as long as it is not oscillating, so a $clear-oscillator-failed issued
    straight after this does not stick. Follow this with $wait-until-running,
    which does that clearing until it holds.
  */
  start -> none:
    update_ reg.SECONDS: it & ~reg.SECONDS-STOP

  /**
  Waits until the clock is actually ticking.

  $start only releases the oscillator; the crystal takes about half a second
    to come back, and the clock is not keeping time until it does. The chip
    re-raises the oscillator-fail flag for as long as it is not oscillating, so
    this clears the flag and checks whether it stays cleared, repeating until it
    does.

  *Clears the oscillator-fail flag.* Once this returns the flag no longer
    reports that the time is stale, and it is: the clock resumed where it was
    halted, so it is behind by however long that was. Follow with $set-time
    unless the old time is good enough.

  # Errors
  Throws if the clock is stopped, so call $start first.

  Throws if the flag keeps coming back for $timeout, which means the crystal is
    not oscillating.
  */
  wait-until-running --timeout/Duration=DEFAULT-WAIT-TIMEOUT -> none:
    if not is-running: throw "BQ32000: clock is stopped"
    deadline := Time.monotonic-us + timeout.in-us
    while true:
      clear-oscillator-failed
      // Give the chip a chance to raise the flag again before believing it.
      sleep --ms=WAIT-POLL-MS_
      if not oscillator-failed: return
      if Time.monotonic-us >= deadline:
        throw "BQ32000: oscillator did not start"

  /**
  Halts the oscillator.

  The clock registers keep their value but stop advancing. This lowers the
    backup-battery drain when the device is stored for a long time.

  The chip cannot tell a deliberate halt from a failed oscillator, so this sets
    the oscillator-fail flag and $read-time refuses to return a time until the
    flag is cleared. That is not a false alarm: the clock resumes where it was
    halted, so it really is behind by however long it was stopped.

  The STOP bit survives a power cycle, so a stopped clock stays stopped until
    $start or $set-time is called.
  */
  stop -> none:
    update_ reg.SECONDS: it | reg.SECONDS-STOP

  /**
  Whether the oscillator has failed since the flag was last cleared.

  The chip sets this flag when it detects a stopped oscillator, which is the
    usual sign of a drained backup battery, and it is always set on a chip that
    has never been set. Halting the oscillator with $stop sets it too. The time
    in the clock registers must not be trusted while it is set.
  */
  oscillator-failed -> bool:
    return ((registers_.read-u8 reg.MINUTES) & reg.MINUTES-OF) != 0

  /**
  Clears the oscillator-fail flag.

  Only do this after writing a known-good time with $set-time, which clears the
    flag by itself.
  */
  clear-oscillator-failed -> none:
    update_ reg.MINUTES: it & ~reg.MINUTES-OF

  /**
  The calibration of the oscillator.

  The value is in the range -31 to 31. Positive values speed the clock up in
    steps of about 4.07ppm, negative values slow it down in steps of about
    2.03ppm, so the range is asymmetric: -63ppm to +126ppm.

  The correction is applied every 8 to 16 minutes, not continuously.
  */
  calibration -> int:
    value := registers_.read-u8 reg.CAL-CFG1
    magnitude := value & reg.CAL-CFG1-CAL
    return (value & reg.CAL-CFG1-S) != 0 ? magnitude : -magnitude

  /**
  Sets the oscillator calibration to $value.

  See $calibration for the meaning of $value.

  # Errors
  It is an error to pass a $value outside the range -31 to 31.
  */
  set-calibration value/int -> none:
    if value < -31 or value > 31:
      throw "BQ32000: calibration $value out of range"
    bits := value >= 0
        ? reg.CAL-CFG1-S | value
        : -value
    update_ reg.CAL-CFG1: (it & ~(reg.CAL-CFG1-S | reg.CAL-CFG1-CAL)) | bits

  /**
  Drives a square wave of the given $frequency on the IRQ pin.

  The $frequency must be $SQUARE-WAVE-1HZ or $SQUARE-WAVE-512HZ. Only the 1Hz
    output reflects the setting made with $set-calibration; the 512Hz output is
    uncalibrated.

  The frequency lives in the key-protected special-function register and is
    reset on every power event, so this must be called again after a power
    loss.

  The IRQ pin is open-drain and needs an external pull-up. Pull it up to VCC,
    not to a rail that survives VCC loss, or the backup cell drains.

  # Errors
  It is an error to pass any other $frequency.
  */
  configure-square-wave --frequency/int -> none:
    ftf/int := ?
    if frequency == SQUARE-WAVE-1HZ: ftf = reg.SFR-FTF
    else if frequency == SQUARE-WAVE-512HZ: ftf = 0
    else: throw "BQ32000: unsupported frequency $frequency"
    write-sfr_ ftf
    update_ reg.CAL-CFG1: it | reg.CAL-CFG1-FT

  /**
  Stops the square wave and drives the IRQ pin to a static level.

  If $high is true, the pin is left floating so that the external pull-up takes
    over. Otherwise the pin is pulled low.
  */
  disable-square-wave --high/bool -> none:
    update_ reg.CAL-CFG1: high
        ? (it & ~reg.CAL-CFG1-FT) | reg.CAL-CFG1-OUT
        : it & ~(reg.CAL-CFG1-FT | reg.CAL-CFG1-OUT)

  /**
  Whether the square wave is enabled.

  Returns the state of the frequency-test bit. Use $square-wave-frequency to
    find out which frequency is selected.
  */
  square-wave-enabled -> bool:
    return ((registers_.read-u8 reg.CAL-CFG1) & reg.CAL-CFG1-FT) != 0

  /**
  The frequency the square wave is set to.

  Returns $SQUARE-WAVE-1HZ or $SQUARE-WAVE-512HZ, whether or not the square
    wave is currently enabled.
  */
  square-wave-frequency -> int:
    value := registers_.read-u8 reg.SFR
    return (value & reg.SFR-FTF) != 0 ? SQUARE-WAVE-1HZ : SQUARE-WAVE-512HZ

  /**
  Configures the trickle charger for the backup battery.

  The charger is off when $enabled is false. When it is on, the charge current
    flows through a series diode and a resistor. Setting $bypass-diode shorts
    out the diode, raising the backup voltage by one diode drop.

  The charger is disabled by the chip on every power-on and on every switchover
    to backup, so this must be called again after a power loss.

  Only enable the charger for rechargeable backup cells. Enabling it for a
    primary cell, such as the BR1225 that the datasheet suggests, is a safety
    hazard.
  */
  configure-trickle-charger --enabled/bool --bypass-diode/bool=false -> none:
    if enabled:
      // Arm the enable code first, then close the switch.
      update_ reg.CFG2: | value/int |
        value &= ~(reg.CFG2-TCFE | reg.CFG2-TCHE)
        value |= reg.CFG2-TCHE-ON
        if bypass-diode: value |= reg.CFG2-TCFE
        value
      update_ reg.TCH2: it | reg.TCH2-TCH2
    else:
      update_ reg.TCH2: it & ~reg.TCH2-TCH2
      update_ reg.CFG2: | value/int |
        (value & ~(reg.CFG2-TCFE | reg.CFG2-TCHE)) | reg.CFG2-TCHE-OFF

  /** Whether the trickle charger is enabled. */
  trickle-charger-enabled -> bool:
    if ((registers_.read-u8 reg.TCH2) & reg.TCH2-TCH2) == 0: return false
    return ((registers_.read-u8 reg.CFG2) & reg.CFG2-TCHE) == reg.CFG2-TCHE-ON

  /**
  Reads the seven clock registers.

  The chip does not latch them for the duration of a read, so the read is
    repeated until the seconds register is unchanged by the time the burst
    finishes.
  */
  read-clock_ -> ByteArray:
    READ-ATTEMPTS_.repeat:
      bytes := registers_.read-bytes reg.SECONDS 7
      if (registers_.read-u8 reg.SECONDS) == bytes[0]: return bytes
    throw "BQ32000: unstable clock read"

  /**
  Writes $value to the special-function register.

  Every write must be preceded by the two magic keys, and the unlock is
    consumed by a single write, so this always sends all three bytes.
  */
  write-sfr_ value/int -> none:
    registers_.write-u8 reg.SFKEY1 reg.SFKEY1-MAGIC
    registers_.write-u8 reg.SFKEY2 reg.SFKEY2-MAGIC
    registers_.write-u8 reg.SFR value

  /**
  Read-modify-writes the register at $address.

  The reserved bits of several registers power up as 1 despite being documented
    as "write as 0", so registers must never be composed from scratch.
  */
  update_ address/int [modify] -> none:
    registers_.write-u8 address (modify.call (registers_.read-u8 address))

from-bcd_ value/int -> int:
  return ((value >> 4) * 10) + (value & 0xf)

to-bcd_ value/int -> int:
  return ((value / 10) << 4) | (value % 10)
