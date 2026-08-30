using Toybox.Math;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;

//! Solar and lunar math. Self-contained so the face does not depend on
//! optional sunrise/sunset APIs that vary between firmware versions.
module Solar {

    const ZENITH = 90.833;          // standard refraction-corrected sunrise
    const D2R = 0.0174532925199433;
    const R2D = 57.2957795130823;

    function sinD(d) { return Math.sin(d * D2R); }
    function cosD(d) { return Math.cos(d * D2R); }
    function tanD(d) { return Math.tan(d * D2R); }
    function asinD(x) { return Math.asin(x) * R2D; }
    function acosD(x) { return Math.acos(x) * R2D; }
    function atanD(x) { return Math.atan(x) * R2D; }

    function norm(v, range) {
        var x = v;
        while (x < 0.0) { x += range; }
        while (x >= range) { x -= range; }
        return x;
    }

    function dayOfYear(info) {
        var cum = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
        var n = cum[info.month - 1] + info.day;
        var y = info.year;
        var leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
        if (leap && info.month > 2) { n += 1; }
        return n;
    }

    //! Sunrise or sunset in minutes UTC, or null above the polar circles.
    //! Almanac algorithm (Sunrise/Sunset, US Naval Observatory).
    function event(n, lat, lon, rising) {
        var lngHour = lon / 15.0;
        var t = rising ? n + ((6.0 - lngHour) / 24.0) : n + ((18.0 - lngHour) / 24.0);

        var m = (0.9856 * t) - 3.289;
        var l = norm(m + (1.916 * sinD(m)) + (0.020 * sinD(2.0 * m)) + 282.634, 360.0);

        var ra = norm(atanD(0.91764 * tanD(l)), 360.0);
        // Put right ascension in the same quadrant as the sun's true longitude.
        var lQuad = Math.floor(l / 90.0) * 90.0;
        var rQuad = Math.floor(ra / 90.0) * 90.0;
        ra = (ra + (lQuad - rQuad)) / 15.0;

        var sinDec = 0.39782 * sinD(l);
        var cosDec = Math.cos(Math.asin(sinDec));

        var cosH = (cosD(ZENITH) - (sinDec * sinD(lat))) / (cosDec * cosD(lat));
        if (cosH > 1.0 || cosH < -1.0) { return null; }   // sun never rises / never sets

        var h = rising ? (360.0 - acosD(cosH)) : acosD(cosH);
        h = h / 15.0;

        var localT = h + ra - (0.06571 * t) - 6.622;
        return norm(localT - lngHour, 24.0) * 60.0;
    }

    //! Returns { :rise, :set, :isDay, :frac } with rise/set as local minutes
    //! past midnight and frac the 0..1 progress through the current day or
    //! night segment. rise/set are null in polar conditions.
    function cycle(lat, lon) {
        var now = Time.now();
        var info = Gregorian.utcInfo(now, Time.FORMAT_SHORT);
        var n = dayOfYear(info);
        var tzMin = System.getClockTime().timeZoneOffset / 60;

        var riseUtc = event(n, lat, lon, true);
        var setUtc = event(n, lat, lon, false);
        if (riseUtc == null || setUtc == null) {
            return { :rise => null, :set => null, :isDay => true, :frac => 0.0 };
        }

        var rise = norm(riseUtc + tzMin, 1440.0);
        var set = norm(setUtc + tzMin, 1440.0);

        var c = System.getClockTime();
        var t = c.hour * 60.0 + c.min + (c.sec / 60.0);

        var isDay = (rise < set) ? (t >= rise && t < set) : (t >= rise || t < set);
        var frac;
        if (isDay) {
            var dayLen = norm(set - rise, 1440.0);
            frac = norm(t - rise, 1440.0) / dayLen;
        } else {
            var nightLen = 1440.0 - norm(set - rise, 1440.0);
            frac = norm(t - set, 1440.0) / nightLen;
        }
        if (frac < 0.0) { frac = 0.0; }
        if (frac > 1.0) { frac = 1.0; }

        return { :rise => rise.toNumber(), :set => set.toNumber(), :isDay => isDay, :frac => frac };
    }

    const SYNODIC = 29.530588853;

    //! Phase fraction: 0 = new, 0.5 = full.
    function phaseFraction() {
        var info = Gregorian.utcInfo(Time.now(), Time.FORMAT_SHORT);
        var y = info.year;
        var m = info.month;
        var d = info.day + (info.hour / 24.0) + (info.min / 1440.0);
        if (m <= 2) { y -= 1; m += 12; }
        var a = Math.floor(y / 100.0);
        var b = 2 - a + Math.floor(a / 4.0);
        var jd = Math.floor(365.25 * (y + 4716)) + Math.floor(30.6001 * (m + 1)) + d + b - 1524.5;
        return norm((jd - 2451550.1) / SYNODIC, 1.0);
    }

    //! Countdown to the next new or full moon, whichever is sooner. Within 24
    //! hours AFTER an event it counts backwards instead, so a moon that has
    //! just been full reads as "-14h" rather than flipping to a 29-day wait.
    //! Returns { :label, :isFull } where isFull names the event referred to.
    function moonEvent() {
        var frac = phaseFraction();
        var sinceNew = frac * SYNODIC;
        var sinceFull = norm(frac - 0.5, 1.0) * SYNODIC;
        var toNew = (1.0 - frac) * SYNODIC;
        var toFull = norm(0.5 - frac, 1.0) * SYNODIC;

        var lastWasFull = sinceFull < sinceNew;
        var since = (sinceFull < sinceNew) ? sinceFull : sinceNew;
        var hoursSince = since * 24.0;
        if (hoursSince < 24.0) {
            return { :label => "-" + Math.round(hoursSince).format("%d") + "h",
                     :isFull => lastWasFull };
        }

        var nextIsFull = toFull < toNew;
        var days = nextIsFull ? toFull : toNew;
        var dd = Math.floor(days);
        var hh = Math.round((days - dd) * 24.0);
        if (hh >= 24) { dd += 1; hh = 0; }
        var label = (dd > 0) ? (dd.format("%d") + "d " + hh.format("%d") + "h")
                             : (hh.format("%d") + "h");
        return { :label => label, :isFull => nextIsFull };
    }
}
