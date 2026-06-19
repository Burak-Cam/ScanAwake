/// FIX-04 / D-07: the camera/vibration restart cooldown after a RESTART
/// dismiss. Safe-side 2.5s value (RLS-05) — pinned by cooldown_value_test.dart.
const int kCameraRestartCooldownMs = 2500;

/// D-01: the maximum number of dismissal barcodes a user may register
/// (CLAUDE.md "barcode CRUD max 3"). Both `_HomeScreenState` barcode guards
/// (length >= [kMaxBarcodes] / length < [kMaxBarcodes]) reference this.
const int kMaxBarcodes = 3;

/// MIS-01 / D-03: the average-luminance threshold (avg-Y on a 0..255 scale)
/// a camera frame must reach to count as "bright enough" for the Lümen
/// mission. Device-calibrated on the Redmi Note 9S (Plan 03 checkpoint): with
/// AUTO-exposure the frame average is pinned to ~mid-gray (~110) no matter how
/// bright the scene, so LumenMission now LOCKS exposure (see lumen_mission.dart)
/// to make the average track real brightness. With exposure locked, 140 sits
/// above the locked ambient baseline so the user must point at a genuinely
/// bright light. Pinned by lumen_hold_test.dart so a regression is caught.
const double kLumenThreshold = 140;

/// MIS-01 / D-02: how long (ms) average luminance must be SUSTAINED at/above
/// [kLumenThreshold] to complete the Lümen mission (~2-3s sustained, NOT
/// cumulative — any drop resets). [ASSUMED] starting value, device-calibrated
/// in Plan 03. Pinned by lumen_hold_test.dart.
const int kLumenHoldMs = 2500;

/// MIS-01 / D-02: pure sustained-hold accumulator. Adds [dtMs] to [heldMs] when
/// the frame's [avgY] is at/above [kLumenThreshold]; otherwise RESETS to 0 (a
/// single below-threshold frame wipes progress — sustained, not cumulative).
int accumulateHold(int heldMs, double avgY, int dtMs) =>
    avgY >= kLumenThreshold ? heldMs + dtMs : 0;

/// MIS-01 / D-02: the Lümen mission is complete once accumulated [heldMs]
/// reaches [kLumenHoldMs].
bool lumenComplete(int heldMs) => heldMs >= kLumenHoldMs;

/// MIS-02 [ASSUMED]: hue match tolerance in degrees (±20°). A sampled frame's
/// hue must be within this circular distance of the target hue to count as a
/// match. Device-calibrated under SC-4 (Plan 02 checkpoint); pinned by
/// color_match_test.dart so calibration is a one-line const change + test
/// update (the Lümen [kLumenThreshold] precedent).
const double kColorHueTolerance = 20;

/// MIS-02 [ASSUMED]: minimum saturation (0..1) a frame must have for its hue to
/// be trusted — rejects achromatic (white/black/gray) frames whose hue is
/// undefined/unstable. Device-calibrated under SC-4; pinned by
/// color_match_test.dart.
const double kColorMinSat = 0.35;

/// MIS-02 [ASSUMED]: minimum value/brightness (0..1) a frame must have — rejects
/// dark frames where hue is unreliable. Device-calibrated under SC-4; pinned by
/// color_match_test.dart.
const double kColorMinVal = 0.25;

/// MIS-02 [ASSUMED]: how long (ms) a matching frame must be SUSTAINED to
/// complete the color mission (~1s, NOT cumulative — any non-matching frame
/// resets). Device-calibrated under SC-4; pinned by color_match_test.dart.
const int kColorHoldMs = 1000;

/// MIS-02: the 6 target hues (degrees) — red 0, orange 30, yellow 60, green
/// 120, blue 220, purple 280. Spaced ~60° apart so the ±[kColorHueTolerance]
/// windows of the green/blue/purple trio never overlap; the warm trio
/// (red/orange/yellow) abuts at the boundary (acceptable — the slot picks ONE
/// target, so a sample only needs to be within tolerance of THAT target).
/// Achromatic colors are excluded by decision. Pinned by color_match_test.dart.
const List<double> kColorPaletteHues = [0, 30, 60, 120, 220, 280];

/// MIS-02: minimal circular hue distance on the 0..360 circle (handles the
/// 0/360 wraparound — e.g. red at 0° vs 350° is 10°, not 350°).
double hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// MIS-02: a single frame matches [targetHue] iff it is within
/// [kColorHueTolerance] degrees AND colorful enough ([kColorMinSat]) AND bright
/// enough ([kColorMinVal]) for the hue to be trustworthy.
bool hsvMatches(double h, double s, double v, double targetHue) =>
    s >= kColorMinSat &&
    v >= kColorMinVal &&
    hueDistance(h, targetHue) <= kColorHueTolerance;

/// MIS-02 / D-02 analog: pure sustained-hold accumulator (NOT cumulative). Adds
/// [dtMs] to [heldMs] while the frame matches [targetHue]; a single
/// non-matching frame RESETS to 0 (mirrors [accumulateHold]).
int accumulateColorHold(
        int heldMs, double h, double s, double v, double targetHue, int dtMs) =>
    hsvMatches(h, s, v, targetHue) ? heldMs + dtMs : 0;

/// MIS-02: the color mission is complete once accumulated [heldMs] reaches
/// [kColorHoldMs].
bool colorComplete(int heldMs) => heldMs >= kColorHoldMs;
