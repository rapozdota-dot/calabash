import 'package:calabash_maturity_detection/main.dart';
import 'package:calabash_maturity_detection/screens/branded_splash_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cases = [
    (size: Size(320, 568), textScale: 1.0, imageFit: BoxFit.cover),
    (size: Size(320, 568), textScale: 1.5, imageFit: BoxFit.cover),
    (size: Size(320, 568), textScale: 2.0, imageFit: BoxFit.cover),
    (size: Size(390, 844), textScale: 1.0, imageFit: BoxFit.cover),
    (size: Size(390, 844), textScale: 1.5, imageFit: BoxFit.cover),
    (size: Size(390, 844), textScale: 2.0, imageFit: BoxFit.cover),
    (size: Size(640, 360), textScale: 1.0, imageFit: BoxFit.contain),
    (size: Size(640, 360), textScale: 1.5, imageFit: BoxFit.contain),
    (size: Size(640, 360), textScale: 2.0, imageFit: BoxFit.contain),
  ];

  for (final testCase in cases) {
    testWidgets(
      'branded splash fits ${testCase.size} at ${testCase.textScale}x text',
      (tester) async {
        tester.view.physicalSize = testCase.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: testCase.size,
                textScaler: TextScaler.linear(testCase.textScale),
                disableAnimations: true,
              ),
              child: const BrandedSplashScreen(),
            ),
          ),
        );

        await tester.pump();

        final backgroundImage = tester.widget<Image>(
          find.byKey(const ValueKey('splash-background')),
        );
        final foregroundImage = tester.widget<Image>(
          find.byKey(const ValueKey('splash-foreground')),
        );
        expect(
          backgroundImage.image,
          isA<AssetImage>().having(
            (image) => image.assetName,
            'assetName',
            'assets/branding/BG.png',
          ),
        );
        expect(
          foregroundImage.image,
          isA<AssetImage>().having(
            (image) => image.assetName,
            'assetName',
            'assets/branding/splash_foreground.png',
          ),
        );
        expect(find.text('CALABASH'), findsOneWidget);
        expect(find.text('MATURITY DETECTION'), findsOneWidget);
        expect(find.text('POWERED BY YOLOv8n-seg'), findsOneWidget);
        expect(find.text('POWERED BY COMPUTER VISION'), findsNothing);
        expect(
          find.text('Intelligent Fruit Maturity Assessment'),
          findsNothing,
        );
        expect(find.text('POWERED BY AI VISION'), findsNothing);
        expect(find.text('POWERED BY AI'), findsNothing);

        expect(backgroundImage.fit, BoxFit.cover);
        expect(foregroundImage.fit, testCase.imageFit);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('background appears before foreground and typography fade in', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(390, 844)),
          child: BrandedSplashScreen(),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('splash-background')), findsOneWidget);
    expect(_fadeValue(tester, const ValueKey('splash-foreground-fade')), 0);
    expect(_fadeValue(tester, const ValueKey('splash-typography-fade')), 0);

    await tester.pump(const Duration(milliseconds: 275));

    final foregroundMid = _fadeValue(
      tester,
      const ValueKey('splash-foreground-fade'),
    );
    final typographyMid = _fadeValue(
      tester,
      const ValueKey('splash-typography-fade'),
    );
    expect(foregroundMid, greaterThan(0));
    expect(foregroundMid, lessThan(1));
    expect(typographyMid, greaterThan(0));
    expect(typographyMid, lessThan(1));

    await tester.pump(const Duration(milliseconds: 425));

    expect(_fadeValue(tester, const ValueKey('splash-foreground-fade')), 1);
    expect(_fadeValue(tester, const ValueKey('splash-typography-fade')), 1);
  });

  testWidgets(
    'splash disables intro animation when reduced motion is enabled',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: BrandedSplashScreen(),
          ),
        ),
      );

      expect(_fadeValue(tester, const ValueKey('splash-foreground-fade')), 1);
      expect(_fadeValue(tester, const ValueKey('splash-typography-fade')), 1);
    },
  );

  testWidgets('startup gate keeps splash visible for the minimum duration', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StartupSplashGate(
          isInitializing: false,
          minimumSplashDuration: Duration(milliseconds: 1700),
          transitionDuration: Duration.zero,
          splash: Text('splash', key: ValueKey('splash')),
          home: Text('home', key: ValueKey('home')),
        ),
      ),
    );

    expect(find.text('splash'), findsOneWidget);
    expect(find.text('home'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1699));

    expect(find.text('splash'), findsOneWidget);
    expect(find.text('home'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('splash'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets(
    'startup gate waits for model initialization after minimum time',
    (tester) async {
      Widget buildGate({required bool isInitializing}) {
        return MaterialApp(
          home: StartupSplashGate(
            isInitializing: isInitializing,
            minimumSplashDuration: const Duration(milliseconds: 1700),
            transitionDuration: Duration.zero,
            splash: const Text('splash', key: ValueKey('splash')),
            home: const Text('home', key: ValueKey('home')),
          ),
        );
      }

      await tester.pumpWidget(buildGate(isInitializing: true));
      await tester.pump(const Duration(seconds: 3));

      expect(find.text('splash'), findsOneWidget);
      expect(find.text('home'), findsNothing);

      await tester.pumpWidget(buildGate(isInitializing: false));
      await tester.pump();

      expect(find.text('splash'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    },
  );

  testWidgets('startup gate crossfades splash into home', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StartupSplashGate(
          isInitializing: false,
          minimumSplashDuration: Duration(milliseconds: 1700),
          transitionDuration: Duration(milliseconds: 300),
          splash: Text('splash', key: ValueKey('splash')),
          home: Text('home', key: ValueKey('home')),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 1700));

    expect(find.text('splash'), findsOneWidget);
    expect(find.text('home'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('splash'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}

double _fadeValue(WidgetTester tester, Key key) {
  return tester.widget<FadeTransition>(find.byKey(key)).opacity.value;
}
