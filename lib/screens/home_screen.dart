import 'package:calabash_maturity_detection/screens/about_screen.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/live_camera_screen.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/navigation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// Shows the branded Home page with distinct live-scan and gallery actions.
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Calabash'),
      actions: [
        IconButton(
          tooltip: 'About this project',
          icon: const Icon(Icons.info_outline_rounded),
          onPressed: () =>
              Navigator.of(context).push(fadeRoute(const AboutScreen())),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 380),
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 12 * (1 - value)),
                  child: child,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFE5EEDC), Color(0xFFF2EBDD)],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.eco_rounded,
                          size: 58,
                          color: AppConstants.primaryGreen,
                        ),
                        const SizedBox(height: 26),
                        Text(
                          'Know your fruit.\nPlan your harvest.',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: const Color(0xFF234429),
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                              ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Calabash Maturity Detection',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Point your camera at a calabash, then capture a photo to check its maturity.',
                          style: TextStyle(
                            color: AppConstants.softText,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  const _ScanActions(),
                  const SizedBox(height: 28),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.offline_bolt_outlined,
                        size: 18,
                        color: AppConstants.mutedText,
                      ),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Private. Offline. Ready for the field.',
                          style: TextStyle(
                            color: AppConstants.mutedText,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ScanActions extends StatelessWidget {
  const _ScanActions();

  /// Rebuilds only scan controls when picker/model busy state changes.
  @override
  Widget build(BuildContext context) => Consumer<DetectionProvider>(
    builder: (context, provider, child) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: provider.isBusy
              ? null
              : () => Navigator.of(
                  context,
                ).push(fadeRoute(const LiveCameraScreen())),
          icon: const Icon(Icons.center_focus_strong_rounded),
          label: const Text('Scan Calabash'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            backgroundColor: AppConstants.primaryGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: provider.isBusy
              ? null
              : () => _chooseImage(context, provider),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Choose from Gallery'),
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        if (provider.isAnalyzing) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text(
            'Analyzing fruit maturity...',
            textAlign: TextAlign.center,
          ),
        ],
        if (provider.errorMessage != null && !provider.isBusy) ...[
          const SizedBox(height: 12),
          Text(
            provider.errorMessage!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppConstants.errorColor),
          ),
        ],
      ],
    ),
  );

  /// Opens the gallery directly and navigates to results only after a successful scan.
  Future<void> _chooseImage(
    BuildContext context,
    DetectionProvider provider,
  ) async {
    final success = await provider.scanFromSource(ImageSource.gallery);
    if (context.mounted && success) {
      await Navigator.of(context).push(fadeRoute(const ResultScreen()));
    }
  }
}
