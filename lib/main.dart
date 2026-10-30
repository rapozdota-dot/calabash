import 'dart:async';

import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/branded_splash_screen.dart';
import 'package:calabash_maturity_detection/screens/home_screen.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/services/performance_probe.dart';
import 'package:calabash_maturity_detection/utils/app_theme.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Starts Flutter and mounts the app; model initialization begins in its provider.
void main() {
  final probe = PerformanceProbe.instance;
  // TEMPORARY: remove after validating the installed iOS diagnostic build.
  debugPrint(
    '[CALABASH_PERF_DIAG] runtime_state '
    'build_enabled=${PerformanceProbe.buildEnabled} '
    'recorder_enabled=${probe.enabled} session=${probe.sessionId} '
    'source_revision=${PerformanceProbe.sourceRevision} '
    'build_number=${PerformanceProbe.buildNumber}',
  );
  if (PerformanceProbe.buildEnabled) {
    WidgetsFlutterBinding.ensureInitialized();
    probe.attachLifecycle();
  }
  runApp(const CalabashApp());
}

class CalabashApp extends StatelessWidget {
  const CalabashApp({super.key});

  /// Creates the shared photo detector and applies the app theme and startup gate.
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DetectionProvider(
        modelService: ModelService(),
        imageService: ImageService(),
      )..initialize(),
      child: MaterialApp(
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        home: const _StartupGate(),
      ),
    );
  }
}

class _StartupGate extends StatelessWidget {
  const _StartupGate();

  static const _minimumSplashDuration = Duration(milliseconds: 1700);
  static const _transitionDuration = Duration(milliseconds: 300);

  /// Observes model initialization so Home appears only after the loading splash.
  @override
  Widget build(BuildContext context) {
    final isInitializing = context.select<DetectionProvider, bool>(
      (provider) => provider.isInitializing,
    );

    return StartupSplashGate(
      isInitializing: isInitializing,
      minimumSplashDuration: _minimumSplashDuration,
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : _transitionDuration,
      splash: const BrandedSplashScreen(key: ValueKey('branded-splash')),
      home: const HomeScreen(key: ValueKey('home')),
    );
  }
}

class StartupSplashGate extends StatefulWidget {
  const StartupSplashGate({
    required this.isInitializing,
    required this.splash,
    required this.home,
    this.minimumSplashDuration = const Duration(milliseconds: 1700),
    this.transitionDuration = const Duration(milliseconds: 300),
    super.key,
  });

  final bool isInitializing;
  final Widget splash;
  final Widget home;
  final Duration minimumSplashDuration;
  final Duration transitionDuration;

  /// Creates the state that owns the minimum splash-duration timer.
  @override
  State<StartupSplashGate> createState() => _StartupSplashGateState();
}

class _StartupSplashGateState extends State<StartupSplashGate> {
  Timer? _minimumSplashTimer;
  bool _minimumSplashElapsed = false;

  /// Starts the minimum display timer without delaying model initialization.
  @override
  void initState() {
    super.initState();
    if (widget.minimumSplashDuration <= Duration.zero) {
      _minimumSplashElapsed = true;
      return;
    }

    _minimumSplashTimer = Timer(widget.minimumSplashDuration, () {
      if (!mounted) return;
      setState(() => _minimumSplashElapsed = true);
    });
  }

  /// Cancels the startup timer so it cannot update an unmounted screen.
  @override
  void dispose() {
    _minimumSplashTimer?.cancel();
    super.dispose();
  }

  /// Crossfades to Home when both the minimum time and model initialization finish.
  @override
  Widget build(BuildContext context) {
    final shouldShowSplash = widget.isInitializing || !_minimumSplashElapsed;

    return AnimatedSwitcher(
      duration: widget.transitionDuration,
      child: shouldShowSplash ? widget.splash : widget.home,
    );
  }
}
