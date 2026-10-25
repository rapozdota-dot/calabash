import 'package:calabash_maturity_detection/utils/constants.dart';
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
                  fontWeight: FontWeight.w900,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('How It Works'),
                      const SizedBox(height: 4),
                      const Text(
                        '1. Take a photo using the camera or choose an image from the gallery.\n'
                        '2. The trained detection model identifies calabash fruits.\n'
                        '3. Segmentation highlights the detected fruit regions.\n'
                        '4. The app displays the predicted maturity stage for each detected fruit.',
                      ),
                      const SizedBox(height: AppConstants.sectionSpacing),
                      _sectionTitle('Maturity Stages'),
                      const SizedBox(height: 4),
                      const Text(
                        'These are visually predicted maturity categories, based on the image:\n\n'
                        'Immature: Predicted to be at an earlier maturity stage.\n'
                        'Mature: Predicted to be at the mature stage.\n'
                        'Overmature: Predicted to be beyond the mature stage.',
                      ),
                      const SizedBox(height: AppConstants.sectionSpacing),
                      _sectionTitle('Understanding Model Confidence'),
                      const SizedBox(height: 4),
                      const Text(
                        "The model confidence score describes how strongly the model favors a predicted maturity class. It does not represent the model's measured accuracy or statistical margin of error.",
                      ),
                      const SizedBox(height: AppConstants.sectionSpacing),
                      _sectionTitle('Important Limitations'),
                      const SizedBox(height: 4),
                      const Text(
                        'This application evaluates visible surface characteristics only. It cannot determine internal fruit maturity, internal quality, or safety. Results may also be affected by lighting, image quality, background conditions, and fruit visibility.\n\n'
                        'The application supports visual assessment and does not replace additional inspection or expert judgment.',
                      ),
                      const SizedBox(height: AppConstants.sectionSpacing),
                      _sectionTitle('Tips for Better Detection'),
                      const SizedBox(height: 4),
                      const Text(
                        '• Use adequate lighting.\n'
                        '• Keep the fruit clearly visible.\n'
                        '• Hold the camera steady.\n'
                        '• Avoid excessive distance.\n'
                        '• Try another angle if detection fails.',
                      ),
                      const SizedBox(height: AppConstants.sectionSpacing),
                      _sectionTitle('Developers'),
                      const SizedBox(height: 4),
                      const Text(
                        'Ralph Laurenz G. Medino\nMaxine Grace C. Emnas\nJohn Carlo M. Bino\nDarren A. Zuniega\n\nInstitution: Leyte Normal University',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              Card(
                color: AppConstants.secondaryLightGreen.withValues(alpha: 0.24),
                child: const Padding(
                  padding: EdgeInsets.all(AppConstants.cardPadding),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.offline_bolt_rounded),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Offline-ready: after installation, image analysis can run without internet access.',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
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
  Widget _sectionTitle(String text) {
    return Text(text, style: const TextStyle(fontWeight: FontWeight.w900));
  }
}
