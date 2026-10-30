import 'package:calabash_maturity_detection/screens/about_screen.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/live_camera_screen.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:calabash_maturity_detection/services/performance_probe.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/navigation.dart';
import 'package:calabash_maturity_detection/widgets/information_button.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.performanceProbe});

  final PerformanceProbe? performanceProbe;

  /// Shows the branded Home page with distinct live-scan and gallery actions.
  @override
  Widget build(BuildContext context) =>
      _buildHome(context, performanceProbe ?? PerformanceProbe.instance);

  Widget _buildHome(BuildContext context, PerformanceProbe probe) => Scaffold(
    appBar: AppBar(
      title: const Text('Calabash'),
      actions: [
        InformationIconButton(
          tooltip: 'About this project',
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
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: const Color(0xFF234429),
                                height: 1.15,
                              ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Calabash Maturity Detection',
                          style: Theme.of(context).textTheme.titleMedium,
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
                  const SizedBox(height: 16),
                  _PerformanceRecordingStatus(probe: probe),
                  const SizedBox(height: 12),
                  _ExportPerformanceButton(probe: probe),
                  const SizedBox(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.offline_bolt_outlined,
                        size: 18,
                        color: AppConstants.mutedText,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Private. Offline. Ready for the field.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppConstants.mutedText),
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

class _PerformanceRecordingStatus extends StatelessWidget {
  const _PerformanceRecordingStatus({required this.probe});

  final PerformanceProbe probe;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: probe,
    builder: (context, _) {
      final enabled = probe.enabled;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                enabled
                    ? 'Performance recording is enabled'
                    : 'Performance recording is disabled',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (enabled) ...[
                const SizedBox(height: 8),
                const Text('Model: ${PerformanceProbe.modelVariant}'),
                const Text(
                  'Export includes Excel workbook, raw CSVs and session metadata.',
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    for (final method in PerformanceScanMethod.values)
                      Text(
                        'Valid ${method.label} inference: ${probe.summaryFor(method).inferenceValidCount} / 30',
                      ),
                  ],
                ),
                Text(
                  'Measurements this session: ${probe.totalMeasurementCount}',
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      'Live Detection: ${probe.measurementCountFor(PerformanceScanMethod.live)}',
                    ),
                    Text(
                      'Capture: ${probe.measurementCountFor(PerformanceScanMethod.capture)}',
                    ),
                    Text(
                      'Gallery: ${probe.measurementCountFor(PerformanceScanMethod.gallery)}',
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 4),
                const Text(
                  'This build does not have performance recording enabled.',
                ),
              ],
              if (probe.lastError != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Performance data could not be saved. Check device storage and try exporting again.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _ExportPerformanceButton extends StatefulWidget {
  const _ExportPerformanceButton({required this.probe});

  final PerformanceProbe probe;

  @override
  State<_ExportPerformanceButton> createState() =>
      _ExportPerformanceButtonState();
}

class _ExportPerformanceButtonState extends State<_ExportPerformanceButton> {
  bool _isExporting = false;

  Future<void> _export() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final zip = await widget.probe.exportZip();
      if (!mounted) return;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(zip.path, mimeType: 'application/zip')],
          subject: 'Calabash performance data',
          text: 'Performance Excel + CSV export: ${zip.uri.pathSegments.last}',
        ),
      );
      if (!mounted) return;
      final message = switch (result.status) {
        ShareResultStatus.success => 'Performance ZIP shared.',
        ShareResultStatus.dismissed =>
          'Sharing was cancelled. The ZIP remains saved in app storage.',
        ShareResultStatus.unavailable =>
          'The ZIP is saved in app storage, but sharing is unavailable.',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      final message = switch (error) {
        NoPerformanceDataException() => NoPerformanceDataException.message,
        StateError()
            when error.message ==
                'Performance recording is not enabled in this build.' =>
          'This build does not have performance recording enabled.',
        _ => 'Performance export failed. Check device storage and try again.',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: _isExporting ? null : _export,
    icon: _isExporting
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.file_download_outlined),
    label: Text(
      _isExporting ? 'Preparing Performance ZIP...' : 'Export Performance Data',
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
          label: const Text('LIVE CAMERA'),
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
    if (context.mounted &&
        success &&
        ModalRoute.of(context)?.isCurrent == true) {
      await Navigator.of(context).push(fadeRoute(const ResultScreen()));
    }
  }
}
