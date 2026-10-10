import 'package:flutter/services.dart' show MethodChannel;

/// Review 2026-10-10 #7: the ONE Dart definition of MainActivity's single
/// native channel — lock-screen re-assert, keep-screen-on, alarm-stream
/// volume, exact-alarm and kill-warning helpers all live on it. The name is
/// shared ON PURPOSE (project memory): do not rename it and do not open a
/// second channel; add a method to MainActivity's handler instead.
const MethodChannel kNativeChannel = MethodChannel('com.burakcam.uyan/keyguard');
