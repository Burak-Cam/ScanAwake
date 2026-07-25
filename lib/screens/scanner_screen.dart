import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_strings.dart';
import '../services/camera_handoff.dart';

class ScannerScreen extends StatefulWidget {
  final String language;
  const ScannerScreen({super.key, required this.language});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> with WidgetsBindingObserver {
  // Created lazily in a postFrameCallback (NOT as an autostarting field
  // initializer). On the single-camera MIUI device (Redmi Note 9S, "Max allowed
  // cameras: 1"), the previous screen's MobileScanner releases the native camera
  // ASYNCHRONOUSLY and UNAWAITED on dispose. Building+autostarting a new
  // controller synchronously in build races that teardown and fails to acquire,
  // rendering a silent black preview. Deferring creation to after the first frame
  // gives the prior camera a moment to release. The auto-retrying errorBuilder
  // below self-heals any remaining transient acquire failure.
  MobileScannerController? controller;
  bool isCameraReady = false;
  bool isScanCompleted = false;

  // Auto-retry bookkeeping for transient camera-acquire failures.
  int _retryCount = 0;
  static const int _maxRetries = 3;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // FIX 2026-07-26 (silent camera death): same process-singleton hazard as
      // RingScreen — a mission's detached camera teardown ends in
      // processCameraProvider.unbindAll(), which would unbind this scanner's use
      // cases too. Wait (bounded) for any in-flight release before binding.
      // This surface is where the dark-preview symptom was FIRST reported (999.1).
      await CameraHandoff.awaitRelease();
      if (!mounted) return;
      _initController();
      setState(() => isCameraReady = true);
    });
  }

  void _initController() {
    // PRESERVED detection-reliability config from abe95e5: dense real-product
    // EAN-13 codes decode slowly at the 640x480 default on low-end / MIUI
    // devices. DetectionSpeed.normal + a short timeout retries decoding ~10x/sec
    // and 1080p gives ML Kit more pixels-per-bar. Formats left unconstrained so
    // any saved barcode format can be re-scanned. The isScanCompleted guard makes
    // any repeated emission harmless. Return contract (barcodes.first.rawValue)
    // is unchanged.
    controller = MobileScannerController(
      torchEnabled: false,
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 100,
      cameraResolution: const Size(1920, 1080),
    );
  }

  // Self-heal a transient camera-acquire failure (release race on the
  // single-camera MIUI device): stop and restart the controller a few times with
  // a short backoff before giving up to the user-driven retry UI.
  void _scheduleAutoRetry() {
    if (_retryCount >= _maxRetries) return;
    if (_retryTimer?.isActive ?? false) return;
    _retryCount++;
    _retryTimer = Timer(Duration(milliseconds: 300 * _retryCount), () async {
      if (!mounted || controller == null) return;
      try {
        await controller!.stop();
      } catch (_) {
        // ignore — controller may already be stopped
      }
      if (!mounted || controller == null) return;
      try {
        await controller!.start();
      } catch (_) {
        // a failed start surfaces again via errorBuilder, which re-schedules
      }
    });
  }

  Future<void> _manualRetry() async {
    _retryCount = 0;
    _retryTimer?.cancel();
    if (controller == null) return;
    try {
      await controller!.stop();
    } catch (_) {}
    if (!mounted || controller == null) return;
    try {
      await controller!.start();
    } catch (_) {}
  }

  // HEALTH M-5: swallow a detached platform-channel future so a post-unmount
  // rejection can never surface as an unhandled exception (Future<void> only).
  void _detachFuture(Future<void> f) => f.then((_) {}, onError: (Object _) {});

  @override
  void dispose() {
    // MIUI/Redmi allows only one open camera at a time. Stop the camera FIRST to
    // shorten the native release window (so the next ScannerScreen/RingScreen
    // open is less likely to race the teardown), then dispose. dispose() cannot
    // be async, so these are best-effort but fired before the controller is
    // torn down.
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // HEALTH M-5: null the field first, then detach each future. `stop()`/`dispose()`
    // return platform-channel futures; an unawaited rejection AFTER unmount is the
    // `releaseFlutterSurfaceTexture` unhandled-PlatformException class RingScreen was
    // explicitly hardened against (WR-02) — ScannerScreen had the raw unguarded calls.
    final c = controller;
    controller = null;
    if (c != null) {
      _detachFuture(c.stop());
      _detachFuture(c.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.get('scan_title', widget.language)), backgroundColor: Colors.black, actions: [
        if (isCameraReady && controller != null)
          ValueListenableBuilder(
            valueListenable: controller!,
            builder: (context, state, child) => IconButton(
              icon: Icon(state.torchState == TorchState.on ? Icons.flash_on : Icons.flash_off, color: state.torchState == TorchState.on ? Colors.yellow : Colors.grey),
              onPressed: () => controller?.toggleTorch(),
            ),
          ),
      ]),
      body: Stack(
        children: [
          if (isCameraReady && controller != null)
            MobileScanner(
              controller: controller!,
              // Production errorBuilder: a camera-acquire failure (release race on
              // the single-camera device) self-heals via _scheduleAutoRetry, and
              // shows a tap-to-retry surface meanwhile — never a permanent silent
              // black preview.
              errorBuilder: (context, error, child) {
                _scheduleAutoRetry();
                return GestureDetector(
                  onTap: _manualRetry,
                  child: Container(
                    color: Colors.black,
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.refresh, color: Colors.white, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            AppStrings.get('camera_retry', widget.language),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
              onDetect: (capture) async {
                if (isScanCompleted) return;
                final List<Barcode> barcodes = capture.barcodes;
                if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                  setState(() => isScanCompleted = true);
                  HapticFeedback.mediumImpact();
                  final value = barcodes.first.rawValue;
                  // Stop the camera BEFORE popping so its native release starts
                  // immediately, shrinking the window in which the next scanner
                  // open could race the teardown.
                  try {
                    await controller?.stop();
                  } catch (_) {}
                  if (!context.mounted) return;
                  Navigator.pop(context, value);
                }
              },
            )
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 20),
                  Text(AppStrings.get('camera_starting', widget.language), style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
          Positioned(
            bottom: 50, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text(AppStrings.get('flash_hint', widget.language), style: const TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
