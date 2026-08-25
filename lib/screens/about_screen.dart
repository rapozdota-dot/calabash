import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppConstants.appName,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppConstants.primaryGreen,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Calabash Maturity Detection uses deep learning and computer vision to assist farmers in determining optimal harvest time.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('Project Purpose'),
                      const SizedBox(height: 4),
                      const Text(
                        'This app supports faster and more accurate field decisions by classifying calabash fruits into Immature, Mature, and Overmature stages.',
                      ),
                      const SizedBox(height: 14),
                      _sectionTitle('Research Description'),
                      const SizedBox(height: 4),
                      const Text(
                        'The system applies a TensorFlow Lite model running directly on-device. It analyzes fruit images, draws detection boxes, and presents maturity summaries with simple harvest recommendations.',
                      ),
                      const SizedBox(height: 14),
                      _sectionTitle('Developers'),
                      const SizedBox(height: 4),
                      const Text(
                        'Research Team: Ralph Laurenz G. Medino\nCarlo Bino\nMaxine Emnas\n Darren Zuniega\nInstitution: Leyte Normal University',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Card(
                color: AppConstants.secondaryLightGreen.withValues(alpha: 0.24),
                child: const Padding(
                  padding: EdgeInsets.all(16),
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

  Widget _sectionTitle(String text) {
    return Text(text, style: const TextStyle(fontWeight: FontWeight.w900));
  }
}
