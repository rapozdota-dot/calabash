import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/navigation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class CameraScreen extends StatelessWidget {
  const CameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<DetectionProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          appBar: AppBar(title: const Text('Scan Calabash')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ScanPanel(isBusy: provider.isBusy),
                  const SizedBox(height: 18),
                  ElevatedButton.icon(
                    onPressed: provider.isBusy
                        ? null
                        : () => _scan(context, provider, ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('Use Camera'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: provider.isBusy
                        ? null
                        : () => _scan(context, provider, ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('Choose from Gallery'),
                  ),
                  if (provider.errorMessage != null) ...[
                    const SizedBox(height: 14),
                    _ErrorBanner(message: provider.errorMessage!),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _scan(
    BuildContext context,
    DetectionProvider provider,
    ImageSource source,
  ) async {
    final success = await provider.scanFromSource(source);
    if (!context.mounted || !success) {
      return;
    }
    Navigator.of(context).pushReplacement(fadeRoute(const ResultScreen()));
  }
}

class _ScanPanel extends StatelessWidget {
  const _ScanPanel({required this.isBusy});

  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppConstants.secondaryLightGreen),
      ),
      child: Column(
        children: [
          Icon(
            isBusy ? Icons.analytics_rounded : Icons.center_focus_strong_rounded,
            size: 52,
            color: AppConstants.primaryGreen,
          ),
          const SizedBox(height: 12),
          Text(
            isBusy ? 'Analyzing fruit maturity...' : 'Capture a clear calabash image',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Use good lighting and keep the fruit visible inside the frame.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.black.withValues(alpha: 0.60),
                ),
          ),
          if (isBusy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade100),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: Colors.red.shade700),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
