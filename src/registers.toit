// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
Register addresses and bit masks for the BQ32000.

Taken from tables 7-1 and 7-2 of the datasheet, TI SLUS900F.

Addresses 0x0A-0x1F are undocumented, and the auto-increment wrap-around
  behaviour is unspecified, so a burst must never span the gap between $CFG2
  and $SFKEY1.
*/

// Clock registers.

/** Seconds. Holds $SECONDS-STOP on top of the BCD value. */
SECONDS ::= 0x00
/** Minutes. Holds $MINUTES-OF on top of the BCD value. */
MINUTES ::= 0x01
/** Hours, always 24-hour, plus the century bits. */
CENT-HOURS ::= 0x02
/** Day of the week, 1-7. Not derived from $DATE by the chip. */
DAY ::= 0x03
/** Day of the month, BCD. */
DATE ::= 0x04
/** Month, BCD. */
MONTH ::= 0x05
/** Year within the century, BCD 00-99. */
YEARS ::= 0x06

// Configuration registers.

/** Output level, frequency test and calibration. Resets to 0x80. */
CAL-CFG1 ::= 0x07
/** Trickle-charge switch 2. Resets to 0x90. */
TCH2 ::= 0x08
/** Trickle-charge enable and FET bypass. Resets to 0xAA. */
CFG2 ::= 0x09

// Special-function registers.

/** First unlock key. Write $SFKEY1-MAGIC. Always reads back as 0. */
SFKEY1 ::= 0x20
/** Second unlock key. Write $SFKEY2-MAGIC. Always reads back as 0. */
SFKEY2 ::= 0x21
/**
Special function register.

Every write must be preceded by the full key pair; the unlock is single-shot.
*/
SFR ::= 0x22

// Masks within $SECONDS.

/** Halts the oscillator. Preserved across a switchover to backup. */
SECONDS-STOP ::= 0x80
/** The BCD seconds, 00-59. */
SECONDS-VALUE ::= 0x7f

// Masks within $MINUTES.

/** Oscillator-fail flag. Set by the chip, cleared only by writing a 0. */
MINUTES-OF ::= 0x80
/** The BCD minutes, 00-59. */
MINUTES-VALUE ::= 0x7f

// Masks within $CENT-HOURS.

/** Enables the century bit, $CENT-HOURS-CENT. */
CENT-HOURS-CENT-EN ::= 0x80
/** Toggled by the chip when the two-digit year wraps from 99 to 00. */
CENT-HOURS-CENT ::= 0x40
/** The BCD hours, 00-23. */
CENT-HOURS-VALUE ::= 0x3f

// Masks within the remaining clock registers.

/** The day of the week, 1-7. */
DAY-VALUE ::= 0x07
/** The BCD day of the month, 01-31. */
DATE-VALUE ::= 0x3f
/** The BCD month, 01-12. Note that the tens digit is a single bit. */
MONTH-VALUE ::= 0x1f
/** The BCD year, 00-99. */
YEARS-VALUE ::= 0xff

// Masks within $CAL-CFG1.

/** Static level driven on the IRQ pin while $CAL-CFG1-FT is clear. */
CAL-CFG1-OUT ::= 0x80
/** Frequency test. Drives a square wave on the IRQ pin. */
CAL-CFG1-FT ::= 0x40
/** Calibration sign. Set speeds the clock up, clear slows it down. */
CAL-CFG1-S ::= 0x20
/** Calibration magnitude, 0-31. */
CAL-CFG1-CAL ::= 0x1f

// Masks within $TCH2 and $CFG2.
// The reserved bits of both registers power up as 1 despite being documented
// as "write as 0", so these registers must be read-modify-written.

/** Trickle-charge switch 2. Set closes the switch. */
TCH2-TCH2 ::= 0x20
/** Trickle-charge FET bypass. Set shorts out the series diode. */
CFG2-TCFE ::= 0x40
/** Trickle-charge enable. Charging runs only while it equals $CFG2-TCHE-ON. */
CFG2-TCHE ::= 0x0f
/** The only $CFG2-TCHE value that enables charging. */
CFG2-TCHE-ON ::= 0x05
/** The $CFG2-TCHE value the chip resets to, which disables charging. */
CFG2-TCHE-OFF ::= 0x0a

// Masks and magic values within the special-function registers.

/** Selects the 1Hz IRQ output instead of the default 512Hz. */
SFR-FTF ::= 0x01
/** The value that unlocks $SFKEY1. */
SFKEY1-MAGIC ::= 0x5e
/** The value that unlocks $SFKEY2. Must be written after $SFKEY1-MAGIC. */
SFKEY2-MAGIC ::= 0xc7
