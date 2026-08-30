using Toybox.Activity;
using Toybox.ActivityMonitor;
using Toybox.Application;
using Toybox.Application.Properties;
using Toybox.Complications;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;
using Toybox.SensorHistory;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.WatchUi;
using Toybox.Weather;

//! Solar Arc — 454x454 round AMOLED (fr965, venu3).
//!
//! Rows, top to bottom:
//!   58   bluetooth glyph / notification count + envelope / battery
//!   107  sun-on-horizon glyph + "6:36 / 19:44", moon glyph + countdown
//!   207  time (156px) left, DoW / date / temp stacked right
//!   308  heart glyph + HR, BODY, STRESS
//!   336  hairline rule
//!   364  training status + recovery time
//!   426  six-day step history, shared baseline
//!
//! Two arcs on the bezel: solar cycle on top (accent by day, cool by night),
//! step goal on the bottom filling left to right.
//!
//! GEOMETRY NOTES, learned the hard way on device:
//!
//! * Type floor is deliberate. Labels are 17px and values 30-46px. An early
//!   build used 9-12px labels; unreadable at arm's length even though they
//!   looked fine in a mockup on a monitor. Do not shrink them to fit more in.
//!
//! * Anything below y~410 gets crossed by the step arc. Its inner edge is
//!   227 + sqrt(213^2 - dx^2) - 7/2 at horizontal offset dx, so the further
//!   from the vertical axis, the higher the ceiling. The tick baseline of 426
//!   is derived from the OUTERMOST tick (dx = 47), not from the centre.
//!
//! * The time is WIDTH-BOUND and cannot be enlarged in this layout. Measured on
//!   device: "23:59" at 156px is 293px and the stack's widest line ("29 AUG") is
//!   ~100px, which with the 6px gutter fills 399px of the 406px row. Every other
//!   row was scaled up ~20% to match the mockup's visual weight; the time could
//!   not be. If it needs to be bigger, the date stack has to leave this row —
//!   on its own line the time could reach ~215px.
//!
//! * Device cap ink is 0.551 x the nominal font size, whereas CSS cap ink is
//!   ~0.71 x font-size. The same number therefore renders ~22% smaller here than
//!   in the HTML mockup: do not copy sizes across from it, scale them.
//!
//! * Vertical alignment of the date stack against the time is done on INK,
//!   via drawInkTop() / drawInkBaseline() and the INK_*_FRAC constants below.
//!   Neither getFontAscent() nor getTextDimensions() reports cap height — both
//!   return the font box including internal leading, which scales with size, so
//!   aligning a 30px label to 156px digits by either puts the label ~30px too
//!   high. TEXT_JUSTIFY_VCENTER has the same problem. Do not "simplify" this
//!   back to font metrics.
class SolarFaceView extends WatchUi.WatchFace {

    // ---- geometry ----------------------------------------------------
    const CX = 227;
    const CY = 227;
    const ARC_R = 213;
    const ARC_W = 7;

    const Y_STATUS = 58;
    const Y_SUN    = 124;      // baseline: the solar arc's lowest extent
                               // (227 - 213*sin30 = 120.5, + half the 7px stroke)
    const Y_TIME   = 211;      // centre of the time row. Chosen so the ink gaps
                               // above and below the digits are equal (43px each,
                               // measured against the sun/moon and metrics rows).
    const Y_METRIC = 308;
    const Y_RULE   = 336;
    const Y_TRAIN  = 364;
    const Y_TICKS  = 426;      // shared tick baseline

    const X_ROW_LEFT  = 26;
    const X_ROW_RIGHT = 432;

    const TICK_N = 6;
    const TICK_W = 10;
    const TICK_GAP = 10;
    const TICK_MAX_H = 30;

    // ---- palette -----------------------------------------------------
    const C_WHITE = 0xEDE9E3;
    const C_VALUE = 0xDCD7CF;
    const C_MUTED = 0xB5AFA6;
    const C_LABEL = 0x9A958D;
    const C_DIM   = 0x8A857C;
    const C_TRACK = 0x3A3632;
    const C_RULE  = 0x2A2724;
    const C_TICK_MISS = 0x54504B;
    const C_AMBER = 0xE5872F;
    const C_RED   = 0xC9452B;
    const C_GREEN = 0x6FA85A;

    // 2200K ramp for Do Not Disturb
    const W_HI    = 0xE8A855;
    const W_VALUE = 0xD6A667;
    const W_MUTED = 0xC08F52;
    const W_LABEL = 0x9A6A34;
    const W_DIM   = 0x8A5A24;
    const W_ACC   = 0xCE8028;
    const W_ARC   = 0x7A4110;
    const W_TRACK = 0x2E1B08;
    const W_RULE  = 0x3A2410;
    const W_TICK_MISS = 0x5A3A14;

    // always-on ramp, deliberately dim
    const A_TIME  = 0xC97A28;
    const A_COLON = 0x8A4C14;
    const A_LABEL = 0x9A5A18;
    const A_VALUE = 0xC4762A;

    // ---- settings ----------------------------------------------------
    hidden var mAccent = 0xE5622F;
    hidden var mCool = 0x6FA8CF;
    hidden var mScheme = 0;
    hidden var mAodEnabled = true;
    hidden var mDndWarm = true;
    hidden var mTh = { :bodyGood => 60, :bodyMarg => 30, :stressGood => 35, :stressMarg => 65 };

    // ---- runtime -----------------------------------------------------
    hidden var mLowPower = false;
    hidden var mFonts = {};
    hidden var mSolar = null;
    hidden var mSolarStamp = -1;
    hidden var mMoon = null;
    hidden var mLat = 37.77;          // replaced by the first weather fix
    hidden var mLon = -122.42;
    hidden var mRecovery = null;
    hidden var mTrainStatus = null;
    hidden var mHistory = null;
    hidden var mHistoryDay = -1;

    function initialize() {
        WatchFace.initialize();
        loadSettings();
    }

    function onLayout(dc) {
        loadFonts();
        subscribeComplications();
    }

    // ==================================================================
    // settings
    // ==================================================================
    function loadSettings() {
        mAccent     = num(:accentColor, 0xE5622F);
        mCool       = num(:coolColor, 0x6FA8CF);
        mScheme     = num(:scheme, 0);
        mAodEnabled = bool(:aodEnabled, true);
        mDndWarm    = bool(:dndWarm, true);
        mTh = {
            :bodyGood   => num(:bodyGood, 60),   :bodyMarg   => num(:bodyMarg, 30),
            :stressGood => num(:stressGood, 35), :stressMarg => num(:stressMarg, 65)
        };
    }

    hidden function num(key, fallback) {
        try {
            var v = Properties.getValue(key);
            return (v == null) ? fallback : v.toNumber();
        } catch (e) { return fallback; }
    }

    hidden function bool(key, fallback) {
        try {
            var v = Properties.getValue(key);
            return (v == null) ? fallback : v;
        } catch (e) { return fallback; }
    }

    // ==================================================================
    // fonts
    // ==================================================================
    hidden function loadFonts() {
        // Exact face names from the device's simulator.json (fontSet "ww",
        // type system_ttf). The only Latin faces that exist are RobotoRegular,
        // RobotoItalic, RobotoCondensedRegular, RobotoCondensedBold and
        // BionicBold — there is no RobotoBold, RobotoMedium, or any spaced
        // variant. An unknown name makes getVectorFont fail for the WHOLE call,
        // which is what silently dropped every size to a bitmap fallback.
        var bold = ["RobotoCondensedBold", "BionicBold"];
        var med  = ["RobotoCondensedRegular", "RobotoRegular"];
        mFonts = {
            :time      => vec(bold, 156, Graphics.FONT_NUMBER_THAI_HOT),
            :dow       => vec(med,   32, Graphics.FONT_SMALL),
            :date      => vec(bold,  38, Graphics.FONT_MEDIUM),
            :temp      => vec(med,   34, Graphics.FONT_MEDIUM),
            :sun       => vec(med,   38, Graphics.FONT_MEDIUM),
            :status    => vec(med,   34, Graphics.FONT_MEDIUM),
            :count     => vec(bold,  34, Graphics.FONT_MEDIUM),
            :metric    => vec(bold,  48, Graphics.FONT_NUMBER_MEDIUM),
            :mLabel    => vec(med,   20, Graphics.FONT_XTINY),
            :train     => vec(bold,  38, Graphics.FONT_MEDIUM),
            :recov     => vec(med,   38, Graphics.FONT_MEDIUM),
            :aodDate   => vec(med,   36, Graphics.FONT_MEDIUM),
            :aodTime   => vec(med,  132, Graphics.FONT_NUMBER_HOT),
            :aodLabel  => vec(med,   22, Graphics.FONT_XTINY),
            :aodVal    => vec(med,   46, Graphics.FONT_NUMBER_MEDIUM)
        };
    }

    //! Vector font at an exact pixel size, or a fixed system font if the device
    //! has no vector support. mVectorOk records which path was taken: when it is
    //! false every size below is a lie and the layout constants no longer hold,
    //! so check it first if the face looks mis-scaled on a new device.
    hidden var mVectorOk = false;

    hidden function vec(faces, size, fallback) {
        if (Graphics has :getVectorFont) {
            // one name per call: passing an array means one unknown name fails
            // the entire request rather than falling through to the next
            for (var i = 0; i < faces.size(); i += 1) {
                try {
                    var fnt = Graphics.getVectorFont({ :face => faces[i], :size => size });
                    if (fnt != null) {
                        mVectorOk = true;
                        return fnt;
                    }
                } catch (e) { }
            }
        }
        return fallback;
    }

    // ---- ink model ---------------------------------------------------
    //! A device probe (fr965, CIQ 5.2) showed these vector fonts report
    //! ascent + descent == height EXACTLY: 124+32=156, 24+6=30, 29+7=36. There
    //! is no internal leading, so the baseline is simply boxTop + ascent and
    //! needs no estimation at all.
    //!
    //! So the baseline is exactly boxTop + getFontAscent(font). Confirmed by
    //! pixel-scanning a 454x454 simulator capture: the 156px digits' ink ran
    //! y 169..254, and 169 + 85.96 cap = 254.96 with the baseline at boxTop+124.
    //!
    //! Cap height is the one quantity no API reports. Measured from that same
    //! capture: digits 86px at height 156, "SAT" 17px at 30, "29 AUG" 19px at 36,
    //! "62F" 17px at 32 — all ~0.55 x height. CIQ 5.2 has no Dc.getPixel, so this
    //! cannot be scanned at runtime; it is a ratio of height, so it holds at
    //! every size and never needs re-measuring when a size changes.
    const CAP_PER_HEIGHT = 0.551;

    //! Minimum leading between the three stack lines, in pixels.
    const STACK_GAP = 4;

    hidden function capHeight(dc, font) {
        return dc.getFontHeight(font) * CAP_PER_HEIGHT;
    }

    //! Draw so the top of the cap ink lands on y.
    hidden function drawInkTop(dc, x, y, font, txt, justify) {
        dc.drawText(x, y - (dc.getFontAscent(font) - capHeight(dc, font)), font, txt, justify);
    }

    //! Draw so the baseline lands on y. Exact — no estimation involved.
    hidden function drawInkBaseline(dc, x, y, font, txt, justify) {
        dc.drawText(x, y - dc.getFontAscent(font), font, txt, justify);
    }

    // ==================================================================
    // complications
    // ==================================================================
    hidden function subscribeComplications() {
        if (!(Toybox has :Complications)) { return; }
        try {
            Complications.registerComplicationChangeCallback(method(:onComplication));
            if (Complications has :COMPLICATION_TYPE_RECOVERY_TIME) {
                subOne(Complications.COMPLICATION_TYPE_RECOVERY_TIME);
            }
            if (Complications has :COMPLICATION_TYPE_TRAINING_STATUS) {
                subOne(Complications.COMPLICATION_TYPE_TRAINING_STATUS);
            }
        } catch (e) { }
    }

    hidden function subOne(type) {
        try {
            Complications.subscribeToUpdates(new Complications.Id(type));
        } catch (e) { }
    }

    function onComplication(id as Complications.Id) as Void {
        readComplications();
        WatchUi.requestUpdate();
    }

    //! Read current values directly. The change callback only fires when a
    //! value CHANGES, so relying on it alone leaves these null forever when
    //! the value is already settled at startup.
    hidden function readComplications() {
        if (!(Toybox has :Complications)) { return; }
        if (Complications has :COMPLICATION_TYPE_RECOVERY_TIME) {
            var r = readOne(Complications.COMPLICATION_TYPE_RECOVERY_TIME);
            if (r != null) { mRecovery = r; }
        }
        if (Complications has :COMPLICATION_TYPE_TRAINING_STATUS) {
            var t = readText(Complications.COMPLICATION_TYPE_TRAINING_STATUS);
            if (t != null) { mTrainStatus = t; }
        }
    }

    hidden function readOne(type) {
        try {
            var c = Complications.getComplication(new Complications.Id(type));
            if (c != null && c.value != null) { return c.value.toNumber(); }
        } catch (e) { }
        return null;
    }

    //! Training status arrives as a display String — confirmed on fr965/CIQ 5.2,
    //! where the simulator returns "No Result". The numeric-enum branch below is
    //! a fallback for firmware that reports the raw value instead.
    hidden function readText(type) {
        try {
            var c = Complications.getComplication(new Complications.Id(type));
            if (c == null) { return null; }
            if (c.value instanceof Lang.String) { return c.value.toUpper(); }
            if (c.shortLabel != null) { return c.shortLabel.toUpper(); }
            if (c.value != null) { return trainingName(c.value.toNumber()); }
        } catch (e) { }
        return null;
    }

    hidden function trainingName(v) {
        var names = ["NO STATUS", "DETRAINING", "RECOVERY", "MAINTAINING",
                     "PRODUCTIVE", "PEAKING", "OVERREACHING", "UNPRODUCTIVE",
                     "STRAINED"];
        if (v >= 0 && v < names.size()) { return names[v]; }
        return null;
    }

    // ==================================================================
    // power state
    // ==================================================================
    function onEnterSleep() {
        mLowPower = true;
        WatchUi.requestUpdate();
    }

    function onExitSleep() {
        mLowPower = false;
        WatchUi.requestUpdate();
    }

    // ==================================================================
    // render
    // ==================================================================
    function onUpdate(dc) {
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (mLowPower && mAodEnabled) {
            drawAod(dc);
        } else {
            drawFull(dc);
        }
    }

    hidden function palette(dnd) {
        if (dnd) {
            return { :hi => W_HI, :val => W_VALUE, :muted => W_MUTED, :label => W_LABEL,
                     :dim => W_DIM, :lbl => W_LABEL, :accent => W_ACC, :sun => W_ACC,
                     :moon => W_MUTED, :arcDay => W_ARC, :arcNight => W_ARC,
                     :arcStep => W_ARC, :tickMet => W_LABEL, :tickMiss => W_TICK_MISS,
                     :track => W_TRACK, :rule => W_RULE, :flag => false };
        }
        return { :hi => C_WHITE, :val => C_VALUE, :muted => C_MUTED, :label => C_LABEL,
                 :dim => C_DIM, :lbl => mCool, :accent => mAccent, :sun => mAccent,
                 :moon => C_VALUE, :arcDay => mAccent, :arcNight => mCool,
                 :arcStep => mCool, :tickMet => mCool, :tickMiss => C_TICK_MISS,
                 :track => C_TRACK, :rule => C_RULE, :flag => true };
    }

    hidden function drawFull(dc) {
        var ds = System.getDeviceSettings();
        var clock = System.getClockTime();
        var dnd = (ds.doNotDisturb != null && ds.doNotDisturb) && mDndWarm;
        var p = palette(dnd);

        refresh(clock);
        drawArcs(dc, p);
        drawStatus(dc, p, ds);
        drawSunMoonRow(dc, p);
        drawTimeBlock(dc, p, clock, ds);
        drawMetrics(dc, p);
        drawTraining(dc, p);
        drawTicks(dc, p);
    }

    // ---- arcs --------------------------------------------------------
    //! Degrees: 0 = 3 o'clock, increasing counter-clockwise.
    //! Solar arc spans 150 -> 30 through 12 o'clock, filling from the left.
    //! Step arc spans 210 -> 330 through 6 o'clock, also filling from the left.
    hidden function drawArcs(dc, p) {
        dc.setPenWidth(ARC_W);

        dc.setColor(p[:track], Graphics.COLOR_TRANSPARENT);
        dc.drawArc(CX, CY, ARC_R, Graphics.ARC_CLOCKWISE, 150, 30);
        if (mSolar != null && mSolar[:rise] != null) {
            var sweep = 120.0 * mSolar[:frac];
            if (sweep > 0.7) {
                dc.setColor(mSolar[:isDay] ? p[:arcDay] : p[:arcNight], Graphics.COLOR_TRANSPARENT);
                dc.drawArc(CX, CY, ARC_R, Graphics.ARC_CLOCKWISE, 150, 150 - sweep);
            }
        }

        dc.setColor(p[:track], Graphics.COLOR_TRANSPARENT);
        dc.drawArc(CX, CY, ARC_R, Graphics.ARC_COUNTER_CLOCKWISE, 210, 330);
        var am = ActivityMonitor.getInfo();
        if (am != null && am.steps != null && am.stepGoal != null && am.stepGoal > 0) {
            var frac = am.steps.toFloat() / am.stepGoal.toFloat();
            if (frac > 1.0) { frac = 1.0; }
            var sw = 120.0 * frac;
            if (sw > 0.7) {
                dc.setColor(p[:arcStep], Graphics.COLOR_TRANSPARENT);
                dc.drawArc(CX, CY, ARC_R, Graphics.ARC_COUNTER_CLOCKWISE, 210, 210 + sw);
            }
        }
    }

    // ---- status row --------------------------------------------------
    //! Bluetooth glyph, notification count + envelope, battery. No DND badge:
    //! the warm palette is the signal. The count shares the envelope's colour
    //! so the pair reads as one item, and caps at "9+".
    hidden function drawStatus(dc, p, ds) {
        var batt = System.getSystemStats().battery.toNumber();
        var bTxt = batt.format("%d") + "%";
        var battColor = (p[:flag] && batt <= 15) ? C_RED : p[:muted];

        var notes = (ds.notificationCount == null) ? 0 : ds.notificationCount;
        var nTxt = (notes > 9) ? "9+" : notes.format("%d");
        var mailColor = (notes > 0) ? p[:val] : p[:dim];

        var wBt = 22;
        var wMail = 32;
        var wCount = dc.getTextWidthInPixels(nTxt, mFonts[:count]);
        var wBatt = dc.getTextWidthInPixels(bTxt, mFonts[:status]);
        var gap = 30;
        var inner = 8;

        var total = wBt + gap + (wCount + inner + wMail) + gap + wBatt;
        var x = CX - (total / 2);

        var btOk = (ds.phoneConnected != null && ds.phoneConnected);
        drawBluetooth(dc, x + (wBt / 2), Y_STATUS, 30,
                      btOk ? mCool : (p[:flag] ? C_RED : p[:label]));
        x += wBt + gap;

        dc.setColor(mailColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Y_STATUS, mFonts[:count], nTxt,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        x += wCount + inner;
        drawEnvelope(dc, x + (wMail / 2), Y_STATUS, 24, mailColor);
        x += wMail + gap;

        dc.setColor(battColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Y_STATUS, mFonts[:status], bTxt,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---- sun / moon row ----------------------------------------------
    //! One sun glyph for both times, then the moon glyph and its countdown.
    //! The row's baseline is set so its text bottom meets the solar arc's
    //! lowest extent (the arc ends at y 120.5, cap included ~125).
    hidden function drawSunMoonRow(dc, p) {
        var sun = "--:-- / --:--";
        if (mSolar != null && mSolar[:rise] != null) {
            sun = hhmm(mSolar[:rise]) + " / " + hhmm(mSolar[:set]);
        }
        if (mMoon == null) { mMoon = Solar.moonEvent(); }

        var f = mFonts[:sun];
        var wSunIcon = 34;
        var wMoonIcon = 27;
        var inner = 6;
        var gap = 7;

        var wSun = dc.getTextWidthInPixels(sun, f);
        var wMoon = dc.getTextWidthInPixels(mMoon[:label], f);
        var total = (wSunIcon + inner + wSun) + gap + (wMoonIcon + inner + wMoon);
        var x = CX - (total / 2);

        var capS = capHeight(dc, f);
        var iconCy = Y_SUN - (capS / 2);

        drawSun(dc, x + (wSunIcon / 2), iconCy, 30, p[:sun]);
        x += wSunIcon + inner;
        dc.setColor(p[:muted], Graphics.COLOR_TRANSPARENT);
        drawInkBaseline(dc, x, Y_SUN, f, sun, Graphics.TEXT_JUSTIFY_LEFT);
        x += wSun + gap;

        drawMoon(dc, x + (wMoonIcon / 2), iconCy, 27, p[:moon], mMoon[:isFull]);
        x += wMoonIcon + inner;
        dc.setColor(p[:muted], Graphics.COLOR_TRANSPARENT);
        drawInkBaseline(dc, x, Y_SUN, f, mMoon[:label], Graphics.TEXT_JUSTIFY_LEFT);
    }

    // ---- time + date stack -------------------------------------------
    //! Time on the left at its intrinsic width; DoW / date / temp centred in
    //! whatever remains. No seconds: at 156px the digits plus the stack fill
    //! the row, and the date is read far more often than seconds.
    hidden function drawTimeBlock(dc, p, clock, ds) {
        var use24 = ds.is24Hour;
        var h = clock.hour;
        if (!use24) {
            h = h % 12;
            if (h == 0) { h = 12; }
        }
        var hs = use24 ? h.format("%02d") : h.format("%d");
        var ms = clock.min.format("%02d");

        var fT = mFonts[:time];
        var capT = capHeight(dc, fT);
        var inkTop = Y_TIME - (capT / 2);         // centre the digit ink on Y_TIME
        var baseT = inkTop + capT;

        var wh = dc.getTextWidthInPixels(hs, fT);
        var wc = dc.getTextWidthInPixels(":", fT);
        var wm = dc.getTextWidthInPixels(ms, fT);

        var x = X_ROW_LEFT;
        dc.setColor(p[:hi], Graphics.COLOR_TRANSPARENT);
        drawInkTop(dc, x, inkTop, fT, hs, Graphics.TEXT_JUSTIFY_LEFT);
        x += wh + 2;

        // colon raised so it reads as optically centred on the digits
        dc.setColor(p[:accent], Graphics.COLOR_TRANSPARENT);
        drawInkTop(dc, x, inkTop - 10, fT, ":", Graphics.TEXT_JUSTIFY_LEFT);
        x += wc + 2;

        dc.setColor(p[:hi], Graphics.COLOR_TRANSPARENT);
        drawInkTop(dc, x, inkTop, fT, ms, Graphics.TEXT_JUSTIFY_LEFT);
        var timeRight = x + wm;

        // stack: DoW ink top on the digits' ink top, temp baseline on theirs
        var now = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        var dow = now.day_of_week.toUpper();
        var date = now.day.format("%d") + " " + now.month.toUpper();
        var temp = temperature(ds);

        var fD = mFonts[:dow];
        var fDate = mFonts[:date];
        var fTemp = mFonts[:temp];
        // shrink only if the designed sizes cannot fit the digits' ink
        if (capHeight(dc, fD) + capHeight(dc, fDate) + capHeight(dc, fTemp)
            + (2 * STACK_GAP) > capT) {
            var fit = fitStack(dc, capT);
            fD = fit[0];
            fDate = fit[1];
            fTemp = fit[2];
        }

        var stackW = maxOf3(dc.getTextWidthInPixels(dow, fD),
                            dc.getTextWidthInPixels(date, fDate),
                            dc.getTextWidthInPixels(temp, fTemp));
        var sx = timeRight + 6 + ((X_ROW_RIGHT - (timeRight + 6)) / 2);
        if (sx + (stackW / 2) > X_ROW_RIGHT) { sx = X_ROW_RIGHT - (stackW / 2); }

        var mid = Graphics.TEXT_JUSTIFY_CENTER;

        // Distribute: DoW ink top on the digits' ink top, temp baseline on the
        // digits' baseline, slack shared evenly. Cannot overlap by construction.
        var capD = capHeight(dc, fD);
        var capDate = capHeight(dc, fDate);
        var capTemp = capHeight(dc, fTemp);
        var slack = capT - (capD + capDate + capTemp);
        var gap = slack / 2;
        if (gap < 0) { gap = 0; }

        dc.setColor(p[:val], Graphics.COLOR_TRANSPARENT);
        drawInkTop(dc, sx, inkTop, fD, dow, mid);

        dc.setColor(p[:hi], Graphics.COLOR_TRANSPARENT);
        drawInkTop(dc, sx, inkTop + capD + gap, fDate, date, mid);

        dc.setColor(p[:val], Graphics.COLOR_TRANSPARENT);
        drawInkTop(dc, sx, inkTop + capD + capDate + (2 * gap), fTemp, temp, mid);
    }

    //! Largest system fonts whose three lines of ink, plus two gaps, fit inside
    //! the digits' ink height. Only used when vector fonts are unavailable and
    //! the requested pixel sizes are therefore meaningless.
    hidden function fitStack(dc, capT) {
        var ladder = [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL,
                      Graphics.FONT_TINY, Graphics.FONT_XTINY];
        var gap = 5;
        for (var i = 0; i < ladder.size(); i += 1) {
            var mid = ladder[i];
            var small = ladder[(i + 1 < ladder.size()) ? i + 1 : i];
            var total = capHeight(dc, mid) + (2 * capHeight(dc, small)) + (2 * gap);
            if (total <= capT) {
                return [small, mid, small];
            }
        }
        var x = Graphics.FONT_XTINY;
        return [x, x, x];
    }

    hidden function maxOf3(a, b, c) {
        var m = (a > b) ? a : b;
        return (m > c) ? m : c;
    }

    // ---- metrics -----------------------------------------------------
    hidden function drawMetrics(dc, p) {
        var hr = heartRate();
        var bb = bodyBattery();
        var st = stress();

        var fV = mFonts[:metric];
        var fL = mFonts[:mLabel];
        var hrTxt = (hr == null) ? "--" : hr.format("%d");
        var bbTxt = (bb == null) ? "--" : bb.format("%d");
        var stTxt = (st == null) ? "--" : st.format("%d");

        var wHeart = 30;
        var inner = 9;
        var gap = 24;
        var wBodyL = dc.getTextWidthInPixels("BODY", fL);
        var wStressL = dc.getTextWidthInPixels("STRESS", fL);

        var total = (wHeart + inner + dc.getTextWidthInPixels(hrTxt, fV)) + gap
                  + (wBodyL + 8 + dc.getTextWidthInPixels(bbTxt, fV)) + gap
                  + (wStressL + 8 + dc.getTextWidthInPixels(stTxt, fV));
        var x = CX - (total / 2);
        var vc = Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER;

        drawHeart(dc, x + (wHeart / 2), Y_METRIC, 30, p[:accent]);
        x += wHeart + inner;
        dc.setColor(p[:val], Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Y_METRIC, fV, hrTxt, vc);
        x += dc.getTextWidthInPixels(hrTxt, fV) + gap;

        dc.setColor(p[:lbl], Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Y_METRIC, fL, "BODY", vc);
        x += wBodyL + 8;
        dc.setColor(bandColor(bb, mTh[:bodyGood], mTh[:bodyMarg], true, p), Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Y_METRIC, fV, bbTxt, vc);
        x += dc.getTextWidthInPixels(bbTxt, fV) + gap;

        dc.setColor(p[:lbl], Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Y_METRIC, fL, "STRESS", vc);
        x += wStressL + 8;
        dc.setColor(bandColor(st, mTh[:stressGood], mTh[:stressMarg], false, p), Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Y_METRIC, fV, stTxt, vc);

        dc.setPenWidth(1);
        dc.setColor(p[:rule], Graphics.COLOR_TRANSPARENT);
        dc.drawLine(84, Y_RULE, 454 - 84, Y_RULE);
    }

    //! Training status and recovery time. Neither takes threshold colour —
    //! the status word already carries the judgement.
    hidden function drawTraining(dc, p) {
        var status = (mTrainStatus == null) ? "--" : mTrainStatus;
        var recov = (mRecovery == null) ? "--" : mRecovery.format("%d") + "h";

        var fS = mFonts[:train];
        var fR = mFonts[:recov];
        var wS = dc.getTextWidthInPixels(status, fS);
        var wR = dc.getTextWidthInPixels(recov, fR);
        var x = CX - ((wS + 12 + wR) / 2);
        var vc = Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER;

        dc.setColor(p[:hi], Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Y_TRAIN, fS, status, vc);
        dc.setColor(p[:dim], Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + wS + 12, Y_TRAIN, fR, recov, vc);
    }

    // ---- six-day step history ----------------------------------------
    //! Ticks share a baseline so relative heights compare directly. Today is
    //! excluded: it is the bottom arc.
    hidden function drawTicks(dc, p) {
        var hist = stepHistory();
        if (hist == null) { return; }

        var total = TICK_N * TICK_W + (TICK_N - 1) * TICK_GAP;
        var x0 = CX - (total / 2);

        var peak = 1.0;
        for (var i = 0; i < hist.size(); i += 1) {
            if (hist[i] > peak) { peak = hist[i]; }
        }

        for (var i = 0; i < TICK_N; i += 1) {
            var v = (i < hist.size()) ? hist[i] : 0.0;
            var h = Math.round((v / peak) * TICK_MAX_H).toNumber();
            if (h < 3) { h = 3; }
            dc.setColor((v >= 1.0) ? p[:tickMet] : p[:tickMiss], Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x0 + i * (TICK_W + TICK_GAP), Y_TICKS - h, TICK_W, h, 2);
        }
    }

    //! Last six days as a fraction of each day's goal, oldest first.
    hidden function stepHistory() {
        var today = Gregorian.info(Time.now(), Time.FORMAT_SHORT).day;
        if (mHistory != null && mHistoryDay == today) { return mHistory; }

        var out = [];
        try {
            var days = ActivityMonitor.getHistory();
            if (days == null) { return null; }
            var n = days.size();
            if (n > TICK_N) { n = TICK_N; }
            for (var i = 0; i < n; i += 1) {
                var day = days[i];
                var goal = (day.stepGoal != null && day.stepGoal > 0) ? day.stepGoal : 8000;
                var steps = (day.steps == null) ? 0 : day.steps;
                out.add(steps.toFloat() / goal.toFloat());
            }
        } catch (e) { return null; }

        // getHistory() returns newest first; the row reads oldest to newest
        var rev = [];
        for (var i = out.size() - 1; i >= 0; i -= 1) { rev.add(out[i]); }
        mHistory = rev;
        mHistoryDay = today;
        return rev;
    }

    // ---- always-on ---------------------------------------------------
    //! Time, date, body battery only. Regular weight, no arcs, no fills. The
    //! date and body rows are larger than the rest of the AOD because they are
    //! cheap in lit pixels; the time dominates the count, so it stays at 132.
    //! Roughly 8.5% of pixels lit against the 10% AMOLED ceiling. The group
    //! drifts a few pixels each minute for burn-in prevention.
    hidden function drawAod(dc) {
        var clock = System.getClockTime();
        var ds = System.getDeviceSettings();

        var dx = ((clock.min % 4) * 3) - 4;
        var dy = (((clock.min / 4) % 3) * 3) - 3;

        var now = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        dc.setColor(A_LABEL, Graphics.COLOR_TRANSPARENT);
        dc.drawText(CX + dx, 128 + dy, mFonts[:aodDate],
                    now.day_of_week.toUpper() + " " + now.month.toUpper() + " " + now.day.format("%d"),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var h = clock.hour;
        if (!ds.is24Hour) {
            h = h % 12;
            if (h == 0) { h = 12; }
        }
        var hs = ds.is24Hour ? h.format("%02d") : h.format("%d");
        var ms = clock.min.format("%02d");

        var f = mFonts[:aodTime];
        var wh = dc.getTextWidthInPixels(hs, f);
        var wc = dc.getTextWidthInPixels(":", f);
        var wm = dc.getTextWidthInPixels(ms, f);
        var x = CX + dx - ((wh + wc + wm + 6) / 2);

        dc.setColor(A_TIME, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, 223 + dy, f, hs, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        x += wh + 3;
        dc.setColor(A_COLON, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, 223 + dy - 13, f, ":", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        x += wc + 3;
        dc.setColor(A_TIME, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, 223 + dy, f, ms, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        var bb = bodyBattery();
        var bTxt = (bb == null) ? "--" : bb.format("%d");
        var wl = dc.getTextWidthInPixels("BODY", mFonts[:aodLabel]);
        var wv = dc.getTextWidthInPixels(bTxt, mFonts[:aodVal]);
        var bx = CX + dx - ((wl + 11 + wv) / 2);

        dc.setColor(A_LABEL, Graphics.COLOR_TRANSPARENT);
        dc.drawText(bx, 322 + dy, mFonts[:aodLabel], "BODY",
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(A_VALUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(bx + wl + 11, 322 + dy, mFonts[:aodVal], bTxt,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ==================================================================
    // icons — drawn from primitives, sized off a nominal height
    // ==================================================================
    hidden function drawBluetooth(dc, cx, cy, h, color) {
        var s = h / 26.0;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(Math.round(2.4 * s).toNumber());
        var x0 = cx - (10.0 * s);
        var y0 = cy - (13.0 * s);
        var pts = [[10, 1.5], [16, 7], [4, 19.5], [10, 1.5],
                   [10, 24.5], [16, 19], [4, 6.5]];
        for (var i = 0; i < pts.size() - 1; i += 1) {
            dc.drawLine(x0 + (pts[i][0] * s), y0 + (pts[i][1] * s),
                        x0 + (pts[i + 1][0] * s), y0 + (pts[i + 1][1] * s));
        }
    }

    hidden function drawEnvelope(dc, cx, cy, h, color) {
        var s = h / 21.0;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(Math.round(2.1 * s).toNumber());
        var w = 28.0 * s;
        var x0 = cx - (w / 2);
        var y0 = cy - (h / 2);
        dc.drawRoundedRectangle(x0, y0, w, h, Math.round(2.4 * s).toNumber());
        dc.drawLine(x0 + (2.6 * s), y0 + (3.6 * s), x0 + (14.0 * s), y0 + (12.6 * s));
        dc.drawLine(x0 + (14.0 * s), y0 + (12.6 * s), x0 + (25.4 * s), y0 + (3.6 * s));
    }

    //! Sun on the horizon: filled half-disc on a rule, three short rays.
    //! One glyph covers both times, so there is no rise/set arrow.
    hidden function drawSun(dc, cx, cy, h, color) {
        var s = h / 24.0;
        var x0 = cx - (15.0 * s);
        var y0 = cy - (12.0 * s);
        var hy = y0 + (18.0 * s);

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, hy, 8.0 * s);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x0 - 1, hy + 1, (32.0 * s), (10.0 * s));

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(Math.round(2.4 * s).toNumber());
        dc.drawLine(x0 + (2.0 * s), hy, x0 + (28.0 * s), hy);
        dc.setPenWidth(Math.round(2.2 * s).toNumber());
        dc.drawLine(cx, y0 + (2.0 * s), cx, y0 + (6.0 * s));
        dc.drawLine(x0 + (4.6 * s), y0 + (6.2 * s), x0 + (7.2 * s), y0 + (8.8 * s));
        dc.drawLine(x0 + (25.4 * s), y0 + (6.2 * s), x0 + (22.8 * s), y0 + (8.8 * s));
    }

    //! Full moon = filled disc, new moon = ring. Names the event being counted
    //! to, not the moon's current shape.
    hidden function drawMoon(dc, cx, cy, d, color, isFull) {
        var r = d / 2.0;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (isFull) {
            dc.fillCircle(cx, cy, r * 0.88);
        } else {
            dc.setPenWidth(Math.round(d / 9.6).toNumber());
            dc.drawCircle(cx, cy, r * 0.77);
        }
    }

    hidden function drawHeart(dc, cx, cy, w, color) {
        var s = w / 26.0;
        var x0 = cx - (13.0 * s);
        var y0 = cy - (11.5 * s);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x0 + (7.2 * s), y0 + (7.4 * s), 5.9 * s);
        dc.fillCircle(x0 + (18.8 * s), y0 + (7.4 * s), 5.9 * s);
        dc.fillPolygon([[x0 + (1.7 * s), y0 + (8.2 * s)],
                        [x0 + (24.3 * s), y0 + (8.2 * s)],
                        [x0 + (13.0 * s), y0 + (21.2 * s)]]);
    }

    // ==================================================================
    // data
    // ==================================================================
    hidden function refresh(clock) {
        var minute = clock.hour * 60 + clock.min;
        if (mSolar != null && mSolarStamp == minute) { return; }
        mSolarStamp = minute;
        readComplications();
        updateLocation();
        mSolar = Solar.cycle(mLat, mLon);
        mMoon = Solar.moonEvent();
    }

    hidden function updateLocation() {
        if (!(Toybox has :Weather)) { return; }
        try {
            var c = Weather.getCurrentConditions();
            if (c != null && c.observationLocationPosition != null) {
                var deg = c.observationLocationPosition.toDegrees();
                mLat = deg[0];
                mLon = deg[1];
            }
        } catch (e) { }
    }

    hidden function temperature(ds) {
        if (!(Toybox has :Weather)) { return "--"; }
        try {
            var c = Weather.getCurrentConditions();
            if (c == null || c.temperature == null) { return "--"; }
            var t = c.temperature;                       // always Celsius
            var suffix = "\u00B0C";
            if (ds.temperatureUnits == System.UNIT_STATUTE) {
                t = (t * 9.0 / 5.0) + 32.0;
                suffix = "\u00B0F";
            }
            return t.toNumber().format("%d") + suffix;
        } catch (e) { return "--"; }
    }

    //! Walk the iterator for the newest sample that actually carries data.
    //! A one-minute period returns an empty iterator on real hardware whenever
    //! the newest sample is older than that, which is most of the time for
    //! body battery and stress — they update every few minutes. The simulator
    //! synthesises a fresh sample every call, which is why a 1-minute window
    //! looked fine there and showed "--" on the watch.
    hidden function newestSample(iter) {
        if (iter == null) { return null; }
        for (var i = 0; i < 8; i += 1) {
            var s = iter.next();
            if (s == null) { return null; }
            if (s.data != null) { return s.data.toNumber(); }
        }
        return null;
    }

    hidden function heartRate() {
        var info = Activity.getActivityInfo();
        if (info != null && info.currentHeartRate != null) { return info.currentHeartRate; }
        if (Toybox has :SensorHistory && SensorHistory has :getHeartRateHistory) {
            try {
                var v = newestSample(SensorHistory.getHeartRateHistory(
                    { :period => 60, :order => SensorHistory.ORDER_NEWEST_FIRST }));
                if (v != null) { return v; }
            } catch (e) { }
        }
        return null;
    }

    hidden function bodyBattery() {
        if (Toybox has :SensorHistory && SensorHistory has :getBodyBatteryHistory) {
            try {
                var v = newestSample(SensorHistory.getBodyBatteryHistory(
                    { :period => 240, :order => SensorHistory.ORDER_NEWEST_FIRST }));
                if (v != null) { return v; }
            } catch (e) { }
        }
        if ((Toybox has :Complications) && (Complications has :COMPLICATION_TYPE_BODY_BATTERY)) {
            return readOne(Complications.COMPLICATION_TYPE_BODY_BATTERY);
        }
        return null;
    }

    hidden function stress() {
        if (Toybox has :SensorHistory && SensorHistory has :getStressHistory) {
            try {
                var v = newestSample(SensorHistory.getStressHistory(
                    { :period => 240, :order => SensorHistory.ORDER_NEWEST_FIRST }));
                if (v != null) { return v; }
            } catch (e) { }
        }
        if ((Toybox has :Complications) && (Complications has :COMPLICATION_TYPE_STRESS)) {
            return readOne(Complications.COMPLICATION_TYPE_STRESS);
        }
        return null;
    }

    // ==================================================================
    // value-dependent color
    // ==================================================================
    //! Scheme 0 leaves good values white so a normal day stays quiet.
    //! Scheme 1 is green/amber/red. Scheme 2 ignores bands and maps
    //! magnitude onto cool -> white -> warm.
    hidden function bandColor(v, good, marginal, higherIsBetter, p) {
        if (v == null) { return p[:dim]; }
        if (!p[:flag]) { return p[:hi]; }            // DND: no alarms

        if (mScheme == 2) {
            if (v < 34) { return mCool; }
            if (v < 67) { return C_WHITE; }
            return mAccent;
        }

        var band;
        if (higherIsBetter) {
            band = (v >= good) ? 0 : ((v >= marginal) ? 1 : 2);
        } else {
            band = (v <= good) ? 0 : ((v <= marginal) ? 1 : 2);
        }

        if (band == 0) { return (mScheme == 1) ? C_GREEN : C_WHITE; }
        if (band == 1) { return C_AMBER; }
        return C_RED;
    }

    // ==================================================================
    // formatting
    // ==================================================================
    hidden function hhmm(minutes) {
        var h = (minutes / 60).toNumber() % 24;
        var m = minutes.toNumber() % 60;
        return h.format("%d") + ":" + m.format("%02d");
    }
}
