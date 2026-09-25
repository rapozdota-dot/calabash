import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/screens/about_screen.dart';
import 'package:calabash_maturity_detection/screens/camera_screen.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/navigation.dart';
import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calabash AI'),
        actions: [
          IconButton(
            tooltip: 'About',
            onPressed: () {
              Navigator.of(context).push(fadeRoute(const AboutScreen()));
            },
            icon: const Icon(Icons.info_outline_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _HeroHeader(),
              const SizedBox(height: AppConstants.sectionSpacing),
              const _CalabashIllustration(),
              const SizedBox(height: 22),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(fadeRoute(const CameraScreen()));
                },
                icon: const Icon(Icons.document_scanner_rounded),
                label: const Text('Scan Fruit'),
              ),
              const Spacer(),
              const _OfflineBadge(),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppConstants.cardRadius),
        border: Border.all(color: AppConstants.secondaryLightGreen),
      ),
      child: Column(
        children: [
          Text(
            AppConstants.appName,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: AppConstants.primaryGreen,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Scan a calabash image and get maturity results directly on your phone.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: AppConstants.softText),
          ),
        ],
      ),
    );
  }
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.offline_bolt_rounded, size: 18, color: Colors.black45),
        const SizedBox(width: 6),
        Text(
          'Works offline once installed',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: AppConstants.mutedText,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _CalabashIllustration extends StatelessWidget {
  const _CalabashIllustration();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE4F2DF), Color(0xFFD3EAD0)],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _fruit(MaturityClass.immature),
          _fruit(MaturityClass.mature),
          _fruit(MaturityClass.overmature),
        ],
      ),
    );
  }

  Widget _fruit(MaturityClass maturityClass) {
    final color = maturityClass.color;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          alignment: Alignment.topCenter,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 48,
              height: 58,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            Container(
              width: 9,
              height: 14,
              decoration: BoxDecoration(
                color: AppConstants.accentBrown,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          maturityClass.label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
