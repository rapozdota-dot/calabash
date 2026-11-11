"""Checks that iOS research builds compile and identify recording-enabled apps."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PerformanceRecordingWorkflowTest(unittest.TestCase):
    def test_ios_smoke_test_timeout_and_failure_log_capture_are_explicit(self):
        workflow = (ROOT / '.github' / 'workflows' / 'build-ios.yml').read_text(encoding='utf-8')
        smoke_test = (ROOT / 'integration_test' / 'model_runtime_smoke_test.dart').read_text(encoding='utf-8')
        smoke_support = (ROOT / 'lib' / 'integration_test' / 'smoke_stage_runner.dart').read_text(encoding='utf-8')
        model_service = (ROOT / 'lib' / 'services' / 'model_service.dart').read_text(encoding='utf-8')
        live_worker = (ROOT / 'lib' / 'services' / 'live_inference_worker.dart').read_text(encoding='utf-8')
        native_bridge = (ROOT / 'ios' / 'RunnerTests' / 'RunnerTests.m').read_text(encoding='utf-8')

        smoke = re.search(
            r'(?m)^      - name: Smoke test the actual iOS TFLite runtime before packaging\n'
            r'        timeout-minutes: (\d+)\n(?P<body>[\s\S]+?)(?=^      - name:)',
            workflow,
        )
        self.assertIsNotNone(smoke)
        self.assertLess(int(smoke[1]), 12)
        self.assertNotIn('continue-on-error', smoke['body'])
        self.assertNotRegex(smoke['body'], r'(?m)^        if:')
        self.assertIn('test-without-building', smoke['body'])
        self.assertIn('-parallel-testing-enabled NO', smoke['body'])
        self.assertIn('xcresulttool get test-results tests', smoke['body'])
        self.assertIn('tool/ios_smoke.py validate-results', smoke['body'])
        self.assertIn('INTEGRATION_TEST_IOS_RUNNER(RunnerTests)', native_bridge)
        self.assertIn('CALABASH_TFLITE_SMOKE_TRACE=true', workflow)
        self.assertIn('xcrun simctl bootstatus "$simulator_id" -b', workflow)
        self.assertLess(workflow.index('xcodebuild build-for-testing'), smoke.start())
        self.assertLess(smoke.end(), workflow.index('name: Build unsigned iOS app'))
        self.assertIn('--target=lib/main.dart', workflow)
        self.assertIn('cmp assets/model/model.tflite "$simulator_model"', workflow)
        self.assertIn('--model-sha256 "$IOS_SMOKE_MODEL_SHA"', workflow)
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
        self.assertIn("testWidgets('iOS Flutter test runner startup'", smoke_test)
        self.assertIn("testWidgets('iOS TFLite photo pipeline'", smoke_test)
        self.assertIn("testWidgets('iOS TFLite live worker pipeline'", smoke_test)
        self.assertIn('worker.detect(buildSmokeFrame(1))', smoke_test)
        self.assertIn('service.detectFruitsWithMetrics(file)', smoke_test)
        self.assertIn('return compute(_inferPhoto, (', model_service)
        self.assertIn('_isolate = await Isolate.spawn(', live_worker)
        self.assertIn(
            'await modelService.detectFruitsFromImageWithMetrics(',
            live_worker,
        )

    def test_research_recording_is_enabled_by_default_and_reaches_build_metadata(self):
        workflow = (ROOT / '.github' / 'workflows' / 'build-ios.yml').read_text(encoding='utf-8')
        readme = (ROOT / 'README.md').read_text(encoding='utf-8')

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
