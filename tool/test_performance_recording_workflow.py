"""Checks that iOS research builds compile and identify recording-enabled apps."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PerformanceRecordingWorkflowTest(unittest.TestCase):
    def test_ios_smoke_test_timeout_and_failure_log_capture_are_explicit(self):
        workflow = (ROOT / '.github' / 'workflows' / 'build-ios.yml').read_text()
        smoke_test = (ROOT / 'integration_test' / 'model_runtime_smoke_test.dart').read_text()
        smoke_support = (ROOT / 'lib' / 'integration_test' / 'smoke_stage_runner.dart').read_text()
        model_service = (ROOT / 'lib' / 'services' / 'model_service.dart').read_text()
        live_worker = (ROOT / 'lib' / 'services' / 'live_inference_worker.dart').read_text()

        self.assertRegex(
            workflow,
            re.compile(
                r'name: Smoke test the actual iOS TFLite runtime before packaging\n'
                r'\s+timeout-minutes: 20'
            ),
        )
        self.assertIn(
            'flutter test --verbose integration_test/model_runtime_smoke_test.dart --no-pub',
            workflow,
        )
        self.assertIn('name: Collect iOS simulator launch diagnostics', workflow)
        self.assertIn('if: failure()', workflow)
        self.assertIn('timeout-minutes: 3', workflow)
        self.assertIn('dist/Calabash-ios-simulator-diagnostics/', workflow)
        self.assertRegex(
            workflow,
            re.compile(
                r'name: Preserve iOS model smoke-test diagnostics\n'
                r'\s+if: always\(\)\n'
                r'\s+uses: actions/upload-artifact@v4'
            ),
        )
        self.assertIn('dist/Calabash-model-smoke.log', workflow)
        self.assertIn('timeout: const Timeout(smokeTestTimeout)', smoke_test)
        self.assertIn('const smokeTestTimeout = Duration(minutes: 5);', smoke_support)
        self.assertNotRegex(smoke_test, re.compile(r'\binterpreter\.invoke\s*\('))
        self.assertNotIn('package:tflite_flutter/tflite_flutter.dart', smoke_test)
        self.assertNotIn('stages.runSync(', smoke_test)
        self.assertIn('direct model inference and output validation', smoke_test)
        self.assertIn('worker.detect(buildSmokeFrame(1))', smoke_test)
        self.assertIn('service.detectFruitsWithMetrics(file)', smoke_test)
        self.assertIn('worker.detect(', smoke_test)
        self.assertIn('return compute(_inferPhoto, (', model_service)
        self.assertIn('_isolate = await Isolate.spawn(', live_worker)
        self.assertIn(
            'await modelService.detectFruitsFromImageWithMetrics(',
            live_worker,
        )

    def test_research_recording_is_enabled_by_default_and_reaches_build_metadata(self):
        workflow = (ROOT / '.github' / 'workflows' / 'build-ios.yml').read_text()
        readme = (ROOT / 'README.md').read_text()

        self.assertRegex(
            workflow,
            re.compile(r'performance_recording:[\s\S]*?default: true'),
        )
        self.assertIn('--dart-define="CALABASH_PERF=$CALABASH_PERF"', workflow)
        self.assertIn('echo "Performance recording: $CALABASH_PERF"', workflow)
        self.assertIn('echo "Recording define: CALABASH_PERF=$CALABASH_PERF"', workflow)
        self.assertIn(
            'flutter run -d <android-device-id> --dart-define=CALABASH_PERF=true',
            readme,
        )


if __name__ == '__main__':
    unittest.main()
