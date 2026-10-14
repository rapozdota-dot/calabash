import 'dart:math' as math;

import 'package:flutter/material.dart';

class BrandedSplashScreen extends StatefulWidget {
  const BrandedSplashScreen({super.key});

  static const _backgroundAssetPath = 'assets/branding/BG.png';
  static const _foregroundAssetPath = 'assets/branding/splash_foreground.png';
  static const _nativeGreen = Color(0xFF15351F);
  static const _softIvory = Color(0xFFF2F7E8);
  static const _calabashGreen = Color(0xFFC6E6A0);
  static const _foregroundAspectRatio = 832 / 1248;
  static const _animationDuration = Duration(milliseconds: 700);

  /// Creates the state that owns the loading splash's fade animations.
  @override
  State<BrandedSplashScreen> createState() => _BrandedSplashScreenState();
}

class _BrandedSplashScreenState extends State<BrandedSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _foregroundOpacity;
  late final Animation<double> _typographyOpacity;

  /// Sets up staggered foreground-art and text fades using one animation controller.
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: BrandedSplashScreen._animationDuration,
      vsync: this,
    );
    _foregroundOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 550 / 700, curve: Curves.easeOutCubic),
    );
    _typographyOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(200 / 700, 1, curve: Curves.easeOutCubic),
    );
  }

  /// Respects reduced-motion settings and starts the intro only when needed.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
      return;
    }

    if (_controller.status == AnimationStatus.dismissed) {
      _controller.forward();
    }
  }

  /// Releases the animation controller when the splash leaves the widget tree.
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Fits the loading artwork to the viewport and places readable model-credit text below it.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrandedSplashScreen._nativeGreen,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          final viewportAspectRatio = viewport.width / viewport.height;
          final foregroundFit =
              viewportAspectRatio <= BrandedSplashScreen._foregroundAspectRatio
              ? BoxFit.cover
              : BoxFit.contain;

          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: BrandedSplashScreen._nativeGreen),
              Image.asset(
                BrandedSplashScreen._backgroundAssetPath,
                key: const ValueKey('splash-background'),
                fit: BoxFit.cover,
                alignment: Alignment.center,
                excludeFromSemantics: true,
              ),
              FadeTransition(
                key: const ValueKey('splash-foreground-fade'),
                opacity: _foregroundOpacity,
                child: Image.asset(
                  BrandedSplashScreen._foregroundAssetPath,
                  key: const ValueKey('splash-foreground'),
                  fit: foregroundFit,
                  alignment: Alignment.center,
                  excludeFromSemantics: true,
                ),
              ),
              const _BottomLegibilityGradient(),
              FadeTransition(
                key: const ValueKey('splash-typography-fade'),
                opacity: _typographyOpacity,
                child: SafeArea(
                  minimum: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 430,
                        maxHeight: viewport.height * 0.36,
                      ),
                      child: LayoutBuilder(
                        builder: (context, textConstraints) {
                          final width = math.min(
                            430.0,
                            textConstraints.maxWidth,
                          );

                          return FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.bottomCenter,
                            child: SizedBox(
                              width: width,
                              child: const _SplashTypography(),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BottomLegibilityGradient extends StatelessWidget {
  const _BottomLegibilityGradient();

  /// Darkens the bottom of the artwork so splash text stays legible.
  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0x0015351F), Color(0xCC15351F)],
          stops: [0.42, 0.62, 1],
        ),
      ),
    );
  }
}

class _SplashTypography extends StatelessWidget {
  const _SplashTypography();

  /// Renders the app title and POWERED BY YOLOv8n-seg credit on the loading splash.
  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'CALABASH',
          textAlign: TextAlign.center,
          maxLines: 1,
          style: textTheme.headlineMedium?.copyWith(
            color: BrandedSplashScreen._softIvory,
            fontWeight: FontWeight.w900,
            height: 1.05,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'MATURITY DETECTION',
          textAlign: TextAlign.center,
          maxLines: 1,
          style: textTheme.titleSmall?.copyWith(
            color: BrandedSplashScreen._calabashGreen,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'POWERED BY YOLOv8n-seg',
          textAlign: TextAlign.center,
          maxLines: 1,
          style: textTheme.bodySmall?.copyWith(
            color: BrandedSplashScreen._softIvory.withValues(alpha: 0.90),
            fontWeight: FontWeight.w800,
            height: 1.2,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}
