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

        self.assertRegex(
            workflow,
            re.compile(
                r'name: Smoke test the actual iOS TFLite runtime before packaging\n'
                r'\s+timeout-minutes: 7'
            ),
        )
        self.assertRegex(
            workflow,
            re.compile(
                r'name: Preserve iOS model smoke-test diagnostics\n'
                r'\s+if: always\(\)\n'
                r'\s+uses: actions/upload-artifact@v4'
            ),
        )
        self.assertIn('dist/Calabash-model-smoke*', workflow)
        self.assertIn('xcodebuild build-for-testing', workflow)
        self.assertIn('xcodebuild test-without-building', workflow)
        self.assertIn('tool/validate_ios_release.py xctest', workflow)
        self.assertLess(workflow.index('validate_ios_release.py xctest'),
                        workflow.index('name: Build unsigned iOS app'))
        self.assertIn('timeout: const Timeout(smokeTestTimeout)', smoke_test)
        self.assertIn('const smokeTestTimeout = Duration(minutes: 5);', smoke_support)

    def test_failed_native_smoke_blocks_release_build_and_packaging(self):
        workflow = (ROOT / '.github' / 'workflows' / 'build-ios.yml').read_text(encoding='utf-8')
        steps = {
            step.splitlines()[0]: step
            for step in workflow.split('\n      - name: ')[1:]
        }
        smoke_name = 'Smoke test the actual iOS TFLite runtime before packaging'
        smoke = steps[smoke_name]
        self.assertIn('shell: bash', workflow)  # GitHub's Bash shell enables pipefail.
        self.assertIn('if [[ "$test_status" -ne 0 ]]; then exit "$test_status"; fi', smoke)
        self.assertNotRegex(smoke, r'(?m)^        continue-on-error:')

        for step_name in ('Build unsigned iOS app', 'Package IPA'):
            with self.subTest(step=step_name):
                self.assertLess(workflow.index(smoke_name), workflow.index(step_name))
                # These steps inherit GitHub Actions' success() condition.
                self.assertNotRegex(steps[step_name], r'(?m)^        if:')

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
