// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
Exercises the BQ32000 driver against a real chip.

Everything here needs hardware, so this is not a unit test. Run it with
  `jag run examples/regtest.toit -d <device>` and watch the output.

The test leaves the clock running and set to the host time, or to $REFERENCE if
  the host clock is not set. It does not touch the trickle charger unless
  $TEST-TRICKLE-CHARGER is true; see the warning there.
*/

import bq32000
import expect show *
import i2c

SDA ::= 39
SCL ::= 40

/** A time to write when the host clock is not set. */
REFERENCE ::= Time.utc --year=2026 --month=8 --day=27 --h=12 --m=34 --s=56

/**
Whether to exercise the trickle charger.

Off by default: enabling the charger on a board with a non-rechargeable backup
  cell is a safety hazard, and the driver cannot tell which cell is fitted.
Only turn this on if you know the board has a rechargeable cell.
*/
TEST-TRICKLE-CHARGER ::= false

main:
  bus := i2c.Bus --sda=SDA --scl=SCL
  device := bus.device bq32000.I2C-ADDRESS
  rtc := bq32000.Driver device
  try:
    test-set-and-read rtc
    test-oscillator-fail rtc
    test-stop-and-start rtc
    test-halted-clock rtc
    test-calibration rtc
    test-square-wave rtc
    test-century-rollover rtc
    test-year-range rtc
    if TEST-TRICKLE-CHARGER:
      test-trickle-charger rtc
    else:
      test-trickle-charger-disabled rtc
    print "ALL PASSED"
  finally:
    // Leave the chip in a sane state whatever happened.
    catch --trace: rtc.start
    catch --trace: rtc.wait-until-running
    catch --trace: rtc.set-time now_
    device.close
    bus.close

now_ -> Time:
  host := Time.now
  return host.utc.year >= bq32000.CENTURY-BASE ? host : REFERENCE

test-set-and-read rtc/bq32000.Driver -> none:
  print "-- set-time / read-time"
  written := now_
  rtc.set-time written
  read := rtc.read-time
  drift := (written.to read).in-s
  print "   wrote $written, read $read, drift $(drift)s"
  expect (drift.abs <= 2)

  print "   waiting for the clock to advance"
  sleep --ms=2500
  later := rtc.read-time
  advanced := (read.to later).in-s
  print "   advanced $(advanced)s"
  expect (advanced >= 2 and advanced <= 4)

  // Re-syncing a clock that is already running must skip the settle delay.
  started := Time.monotonic-us
  rtc.set-time now_
  elapsed := (Time.monotonic-us - started) / 1000
  print "   set-time on a running clock took $(elapsed)ms"
  expect (elapsed < 50)

test-oscillator-fail rtc/bq32000.Driver -> none:
  print "-- oscillator-fail flag"
  // set-time clears it.
  expect-not rtc.oscillator-failed
  rtc.clear-oscillator-failed
  expect-not rtc.oscillator-failed
  expect rtc.is-time-valid
  print "   clear after set-time: ok"

test-stop-and-start rtc/bq32000.Driver -> none:
  print "-- stop / start"
  before := rtc.read-time
  expect rtc.is-running

  rtc.stop
  expect-not rtc.is-running
  expect-not rtc.is-time-valid
  // Halting the oscillator is indistinguishable from a failed one, so the chip
  // raises OF, and the time really is no longer valid.
  sleep --ms=2500
  expect rtc.oscillator-failed
  expect-throw "BQ32000: clock is stopped": rtc.read-time
  print "   stopped at $before, OF raised, reads refused"

  rtc.start
  expect rtc.is-running
  started := Time.monotonic-us
  rtc.wait-until-running
  print "   ticking again $((Time.monotonic-us - started) / 1000)ms after start"

  // wait-until-running clears the flag, and it stays clear once the crystal is
  // back. The time it reports is still behind by however long it was halted.
  expect-not rtc.oscillator-failed

  after := rtc.read-time
  lost := (before.to after).in-s
  print "   resumed at $after, $(lost)s on the clock for ~4s of wall time"
  expect (lost <= 3)

test-halted-clock rtc/bq32000.Driver -> none:
  print "-- a halted clock refuses reads and writes"
  rtc.stop
  sleep --ms=1200
  expect-not rtc.is-time-valid
  expect-throw "BQ32000: clock is stopped": rtc.read-time
  expect-throw "BQ32000: clock is stopped": rtc.set-time now_
  expect-throw "BQ32000: clock is stopped": rtc.wait-until-running
  print "   is-time-valid false; read-time, set-time and wait-until-running all refuse"

  rtc.start
  started := Time.monotonic-us
  rtc.wait-until-running
  waited := (Time.monotonic-us - started) / 1000

  // set-time is quick whatever state we came from, now that it never restarts
  // the oscillator itself.
  wanted := now_
  set-started := Time.monotonic-us
  rtc.set-time wanted
  elapsed := (Time.monotonic-us - set-started) / 1000

  // Must actually hold the time we asked for. Writing the burst to a halted
  // clock loses the seconds field, so this catches a regression back to that.
  read := rtc.read-time
  drift := (wanted.to read).in-s
  print "   waited $(waited)ms, set-time took $(elapsed)ms, reads $read, drift $(drift)s"
  expect (drift.abs <= 2)
  expect (elapsed < 50)

test-calibration rtc/bq32000.Driver -> none:
  print "-- calibration"
  original := rtc.calibration
  print "   was $original"
  [31, -31, 7, -7, 0].do: | value/int |
    rtc.set-calibration value
    expect-equals value rtc.calibration
  print "   round-tripped 31, -31, 7, -7, 0"
  expect-throw "BQ32000: calibration 32 out of range": rtc.set-calibration 32
  expect-throw "BQ32000: calibration -32 out of range": rtc.set-calibration -32
  rtc.set-calibration original

test-square-wave rtc/bq32000.Driver -> none:
  print "-- square wave"
  rtc.configure-square-wave --frequency=bq32000.SQUARE-WAVE-1HZ
  expect rtc.square-wave-enabled
  expect-equals bq32000.SQUARE-WAVE-1HZ rtc.square-wave-frequency
  print "   1Hz selected, and it survived the key sequence"

  rtc.configure-square-wave --frequency=bq32000.SQUARE-WAVE-512HZ
  expect rtc.square-wave-enabled
  expect-equals bq32000.SQUARE-WAVE-512HZ rtc.square-wave-frequency
  print "   512Hz selected"

  expect-throw "BQ32000: unsupported frequency 32768":
    rtc.configure-square-wave --frequency=32768

  rtc.disable-square-wave --high
  expect-not rtc.square-wave-enabled
  rtc.disable-square-wave --no-high
  expect-not rtc.square-wave-enabled
  print "   disabled, both levels"

test-century-rollover rtc/bq32000.Driver -> none:
  print "-- century rollover"
  rtc.set-time (Time.utc --year=2099 --month=12 --day=31 --h=23 --m=59 --s=58)
  expect-equals 2099 rtc.read-time.utc.year
  print "   set to $rtc.read-time, waiting for the wrap"
  sleep --ms=3500
  after := rtc.read-time
  print "   now $after"
  info := after.utc
  expect-equals 2100 info.year
  expect-equals 1 info.month
  expect-equals 1 info.day

test-year-range rtc/bq32000.Driver -> none:
  print "-- year range"
  expect-throw "BQ32000: year 1999 out of range":
    rtc.set-time (Time.utc --year=1999 --month=1 --day=1)
  expect-throw "BQ32000: year 2200 out of range":
    rtc.set-time (Time.utc --year=2200 --month=1 --day=1)
  print "   rejects 1999 and 2200"

test-trickle-charger-disabled rtc/bq32000.Driver -> none:
  print "-- trickle charger (disable only)"
  rtc.configure-trickle-charger --no-enabled
  expect-not rtc.trickle-charger-enabled
  rtc.configure-trickle-charger --no-enabled
  expect-not rtc.trickle-charger-enabled
  print "   stays off; set TEST-TRICKLE-CHARGER to exercise the rest"

test-trickle-charger rtc/bq32000.Driver -> none:
  print "-- trickle charger"
  rtc.configure-trickle-charger --enabled
  expect rtc.trickle-charger-enabled
  rtc.configure-trickle-charger --enabled --bypass-diode
  expect rtc.trickle-charger-enabled
  rtc.configure-trickle-charger --no-enabled
  expect-not rtc.trickle-charger-enabled
  print "   enabled, bypassed and disabled again"
