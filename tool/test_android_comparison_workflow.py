"""Protect opt-in recording, side-by-side identities, and pinned model selection."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AndroidComparisonWorkflowTests(unittest.TestCase):
    def test_comparison_build_is_explicitly_enabled_and_identifiable(self):
        text = (ROOT/'.github/workflows/android-release.yml').read_text()
        self.assertIn('variant: [yoloperf, hybridperf]', text)
        self.assertIn('--dart-define=CALABASH_PERF=true', text)
        for field in ('CALABASH_MODEL_VARIANT', 'CALABASH_MODEL_SHA256',
                      'CALABASH_SOURCE_REVISION', 'CALABASH_BUILD_NUMBER'):
            self.assertIn('--dart-define="'+field+'=', text)
        self.assertIn('git show "${model_revision}:assets/model/model.tflite"', text)
        self.assertIn('unzip -p "$apk" assets/flutter_assets/assets/model/model.tflite', text)
        self.assertIn('prerelease: true', text)
        self.assertIn('make_latest: false', text)
        self.assertNotIn('flutter build ios', text)
        self.assertNotIn('flutter build ipa', text)

    def test_launcher_labels_and_application_ids_are_separate(self):
        gradle = (ROOT/'android/app/build.gradle.kts').read_text()
        for value in ('yoloperf', 'hybridperf', 'Calabash YOLO Perf', 'Calabash Hybrid Perf'):
            self.assertIn(value, gradle)
        self.assertIn('applicationIdSuffix = ".$perfVariant"', gradle)


if __name__ == '__main__':
    unittest.main()
