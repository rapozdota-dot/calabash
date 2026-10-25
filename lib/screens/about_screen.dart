import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/prediction_explanations.dart';
import 'package:calabash_maturity_detection/utils/ui_tokens.dart';
import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  /// Explains the app's visual predictions, limitations, and practical scanning tips.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppConstants.pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'About Calabash Maturity Detection',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppConstants.primaryGreen,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This mobile application assists users in identifying the visually estimated maturity stages of calabash fruits through image-based detection and classification.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppConstants.cardPadding),
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.bodyLarge!,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionTitle(context, 'How It Works'),
                        const SizedBox(height: AppConstants.smallSpacing),
                        const Text(
                          '1. Take a photo using the camera or choose an image from the gallery.\n'
                          '2. The trained detection model identifies calabash fruits.\n'
                          '3. Segmentation highlights the detected fruit regions.\n'
                          '4. The app displays the predicted maturity stage for each detected fruit.',
                        ),
                        const SizedBox(height: UiTokens.aboutSectionSpacing),
                        _sectionTitle(context, 'Maturity Stages'),
                        const SizedBox(height: AppConstants.smallSpacing),
                        const Text(
                          'These are visually predicted maturity categories, based on the image:\n\n'
                          'Immature: Predicted to be at an earlier maturity stage.\n'
                          'Mature: Predicted to be at the mature stage.\n'
                          'Overmature: Predicted to be beyond the mature stage.',
                        ),
                        const SizedBox(height: UiTokens.aboutSectionSpacing),
                        _sectionTitle(
                          context,
                          'Understanding Model Confidence',
                        ),
                        const SizedBox(height: AppConstants.smallSpacing),
                        const Text(PredictionExplanations.confidence),
                        const SizedBox(height: UiTokens.aboutSectionSpacing),
                        _sectionTitle(context, 'Important Limitations'),
                        const SizedBox(height: AppConstants.smallSpacing),
                        const Text(
                          'This application evaluates visible surface characteristics only. It cannot determine internal fruit maturity, internal quality, or safety. Results may also be affected by lighting, image quality, background conditions, and fruit visibility.\n\n'
                          'The application supports visual assessment and does not replace additional inspection or expert judgment.',
                        ),
                        const SizedBox(height: UiTokens.aboutSectionSpacing),
                        _sectionTitle(context, 'Tips for Better Detection'),
                        const SizedBox(height: AppConstants.smallSpacing),
                        const Text(
                          '• Use adequate lighting.\n'
                          '• Keep the fruit clearly visible.\n'
                          '• Hold the camera steady.\n'
                          '• Avoid excessive distance.\n'
                          '• Try another angle if detection fails.',
                        ),
                        const SizedBox(height: UiTokens.aboutSectionSpacing),
                        _sectionTitle(context, 'Developers'),
                        const SizedBox(height: AppConstants.smallSpacing),
                        const Text(
                          'Ralph Laurenz G. Medino\nMaxine Grace C. Emnas\nJohn Carlo M. Bino\nDarren A. Zuniega\n\nInstitution: Leyte Normal University',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              Card(
                color: AppConstants.secondaryLightGreen.withValues(alpha: 0.24),
                child: Padding(
                  padding: const EdgeInsets.all(AppConstants.cardPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        runSpacing: AppConstants.smallSpacing,
                        children: [
                          const Icon(
                            Icons.offline_bolt_rounded,
                            color: AppConstants.primaryGreen,
                          ),
                          _sectionTitle(context, 'Offline Functionality'),
                        ],
                      ),
                      const SizedBox(height: AppConstants.smallSpacing),
                      const Text(
                        'Offline-ready: after installation, image analysis can run without internet access.',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Styles section headings consistently within the About page.
  Widget _sectionTitle(BuildContext context, String text) {
    return Semantics(
      header: true,
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(color: AppConstants.primaryGreen),
      ),
    );
  }
}
