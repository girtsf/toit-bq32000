// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import bq32000
import i2c

SDA ::= 39
SCL ::= 40

main:
  bus := i2c.Bus --sda=SDA --scl=SCL
  device := bus.device bq32000.I2C-ADDRESS
  rtc := bq32000.Driver device

  // Only enable this if you have something rechargeable:
  // rtc.configure-trickle-charger --enabled --bypass-diode

  if not rtc.is-time-valid:
    now := Time.now
    if now.utc.year < bq32000.CENTURY-BASE:
      now = Time.utc 2001 1 2 3 4 5
    print "Clock has no valid time. Setting it to $now"
    // set-time refuses to write to a halted clock, so release it first.
    if not rtc.is-running:
      rtc.start
      rtc.wait-until-running
    rtc.set-time now

  print "RTC time: $rtc.read-time"

  device.close
  bus.close
