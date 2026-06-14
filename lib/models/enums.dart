/// ARC-03 / D-03: the typed navigation contract for the four RingScreen dismiss
/// paths, replacing the stringly-typed 'RESTART'/'SNOOZE'/'SUCCESS'/'EMERGENCY'
/// sentinels. Producers (RingScreen `Navigator.pop`) and consumers (HomeScreen
/// ring-listener) are migrated together — Navigator results are `dynamic`, so a
/// half-migration would fail silently and regress the FIX-01 re-arm guarantee
/// (Pitfall 5).
///
/// EXCLUDED from this enum (separate contracts, intentionally untouched):
/// - the alarm-add dialog's `'SAVE'` sentinel
/// - the ScannerScreen's raw barcode `String` return
enum RingResult { restart, snooze, success, emergency }
