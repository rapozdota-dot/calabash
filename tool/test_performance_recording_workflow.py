"""Checks that iOS research builds compile and identify recording-enabled apps."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PerformanceRecordingWorkflowTest(unittest.TestCase):
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
