# bq32000

A Toit driver for the Texas Instruments
[BQ32000](https://www.ti.com/product/BQ32000) I2C real-time clock.

The BQ32000 is a low-power RTC with a backup-battery input, an optional
trickle charger for rechargeable backup cells, a calibration register for
trimming the crystal, and an IRQ pin that can output a 1Hz or 512Hz square
wave.

## Usage

```toit
import bq32000
import i2c

main:
  bus := i2c.Bus --sda=21 --scl=22
  device := bus.device bq32000.I2C-ADDRESS
  rtc := bq32000.Driver device

  if not rtc.is-time-valid:
    // A halted clock must be released, and given time to start, before it
    // takes a new time.
    if not rtc.is-running:
      rtc.start
      rtc.wait-until-running
    rtc.set-time Time.now

  print "RTC time: $rtc.read-time"
```

See [examples/read-time.toit](examples/read-time.toit) for a complete program,
and [examples/regtest.toit](examples/regtest.toit) for a test that exercises
the whole driver against a real chip.

## Features

| Feature                                         | API                                            | Registers      |
| ----------------------------------------------- | ---------------------------------------------- | -------------- |
| Read and write the time, century included       | `read-time`, `set-time`                        | `0x00`-`0x06`  |
| Halt and resume the oscillator                  | `stop`, `start`, `wait-until-running`          | `0x00`         |
| Is the time readable                            | `is-time-valid`                                | `0x00`-`0x01`  |
| Oscillator-fail flag                            | `oscillator-failed`, `clear-oscillator-failed` | `0x01`         |
| Crystal calibration, -63ppm to +126ppm          | `calibration`, `set-calibration`               | `0x07`         |
| 1Hz / 512Hz square wave and static level on IRQ | `configure-square-wave`, `disable-square-wave` | `0x07`, `0x22` |
| Trickle charger for the backup cell             | `configure-trickle-charger`                    | `0x08`, `0x09` |

## Notes

**The time is invalid until you set it.** The chip powers up with the
oscillator-fail flag set and indeterminate date registers, so `read-time`
throws until `set-time` has been called once. Check `oscillator-failed` rather
than trusting a plausible-looking reading.

**Wait more than a second after power-up** before trusting a reading. The chip
otherwise reports the time at which it entered backup mode — a stale value that
looks perfectly valid.

**Halting the clock invalidates it.** The chip cannot tell `stop` from a failed
crystal, so it raises the oscillator-fail flag, and the clock resumes where it
left off rather than catching up.

**Use `is-time-valid` to ask whether a read will work.** It is the AND of "not
stopped" and "not flagged", in one I2C transaction, and it is exactly
`read-time`'s precondition. Checking `oscillator-failed` alone misses the
stopped case.

**A stopped clock refuses reads and writes.** `read-time` and `set-time` both
throw while STOP is set. Restarting is explicit, because the crystal takes
roughly half a second to come back and neither call should hide a delay like
that:

```toit
rtc.start
rtc.wait-until-running
rtc.set-time Time.now
```

`set-time` never blocks — it is a handful of I2C transactions whatever state the
clock is in. `wait-until-running` is the only call that waits: it clears the
oscillator-fail flag and checks that it stays cleared, repeating until the
crystal is back. Note that it therefore *clears* the flag, so it is no longer
there to tell you the time is stale — and it is, by however long the clock was
halted. Follow with `set-time` unless the old time is good enough.

**Writing the time to a halted clock does not work.** On the chip tested here, a
7-byte burst that also clears STOP lands on every field *except* seconds, which
intermittently keeps its old value. That is why `set-time` refuses rather than
restarting the oscillator for you. This is not in the datasheet.

**The century is one toggling bit.** The chip stores two digits of the year and
flips a single bit when they wrap, so the driver covers the 200 years from
`CENTURY-BASE` (2000). The rollover past 2099 is handled and tested. Note that
the chip's leap-year rule is "divisible by 4" on the two-digit year, which is
wrong for 2100.

**The trickle charger is off after every power event** and needs re-enabling.
Only turn it on for a rechargeable backup cell — charging a primary cell such
as the BR1225 is a safety hazard.

**The square-wave frequency does not survive a power event.** It lives in the
key-protected special-function register, which resets to 512Hz. Only the 1Hz
output reflects the calibration setting.

## References

* [BQ32000 datasheet](https://www.ti.com/lit/ds/symlink/bq32000.pdf) (TI SLUS900F)

## AI Disclosure

Robots wrote most of this.
