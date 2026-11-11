"""Verify simulator selection and the XCTest smoke gate with JSON fixtures."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from ios_smoke import select_simulator, validate_results


RUNTIME = 'com.apple.CoreSimulator.SimRuntime.'
FIRST = '11111111-1111-1111-1111-111111111111'
SECOND = '22222222-2222-2222-2222-222222222222'
THIRD = '33333333-3333-3333-3333-333333333333'


def device(udid, name='iPhone 16', state='Shutdown', available=True):
    return {'name': name, 'udid': udid, 'state': state, 'isAvailable': available}


def devices(**runtimes):
    return {'devices': {RUNTIME + runtime.replace('_', '-'): entries
                        for runtime, entries in runtimes.items()}}


def case(selector, result='Passed'):
    return {
        'name': f'{selector}()',
        'nodeIdentifier': f'RunnerTests/{selector}()',
        'nodeType': 'Test Case',
        'result': result,
    }


def passed_cases():
    return [
        case('testIosFlutterTestRunnerStartup'),
        case('testIosTflitePhotoPipeline'),
        case('testIosTfliteLiveWorkerPipeline'),
    ]


def results(cases):
    return {'testNodes': [{
        'name': 'Runner',
        'nodeType': 'Test Plan',
        'children': [{
            'name': 'RunnerTests',
            'nodeType': 'Unit test bundle',
            'children': [{
                'name': 'RunnerTests',
                'nodeType': 'Test Suite',
                'children': cases,
            }],
        }],
    }]}


class SimulatorSelectionTest(unittest.TestCase):
    def test_available_booted_iphone_wins(self):
        selected = select_simulator(devices(
            iOS_26_0=[device(THIRD), device(FIRST, state='Booted', available=False)],
            iOS_18_2=[device(SECOND, state='Booted'), device(THIRD, name='iPad', state='Booted')],
            tvOS_30_0=[device(FIRST, state='Booted')],
        ))
        self.assertEqual(selected.udid, SECOND)

    def test_runtime_version_uses_numeric_order_and_name_then_udid_tiebreak(self):
        entries = [
            device(THIRD, name='iPhone 17'),
            device(SECOND),
            device(FIRST),
        ]
        for same_runtime in (entries, list(reversed(entries))):
            with self.subTest(entries=same_runtime):
                selected = select_simulator(devices(
                    iOS_18_9=[device(SECOND, name='iPhone 15')],
                    iOS_18_10=same_runtime,
                ))
                self.assertEqual(selected.udid, FIRST)
                self.assertEqual(selected.version, (18, 10, 0))

    def test_missing_iphone_fails(self):
        with self.assertRaisesRegex(ValueError, 'No available iPhone simulator'):
            select_simulator(devices(iOS_26_0=[device(FIRST, name='iPad')]))

    def test_cli_only_prints_udid_on_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'devices.json'
            path.write_text(json.dumps(devices(iOS_26_0=[device(FIRST)])), encoding='utf-8')
            command = [sys.executable, str(Path(__file__).with_name('ios_smoke.py')),
                       'select-simulator', str(path)]
            completed = subprocess.run(command, check=True, capture_output=True, text=True)
        self.assertEqual(completed.stdout.strip(), FIRST)
        self.assertIn('Selected iPhone 16', completed.stderr)


class NativeResultsTest(unittest.TestCase):
    def test_all_required_cases_pass_in_nested_tree(self):
        validate_results(results(passed_cases()))

    def test_xcresult_can_omit_node_identifier(self):
        cases = passed_cases()
        del cases[0]['nodeIdentifier']
        validate_results(results(cases))

    def test_empty_and_incomplete_suites_fail(self):
        for cases in ([], passed_cases()[:-1]):
            with self.subTest(cases=cases), self.assertRaisesRegex(ValueError, 'iOS TFLite live worker pipeline'):
                validate_results(results(cases))

    def test_failed_skipped_and_missing_case_status_fail(self):
        for status in ('Failed', 'Skipped', 'Expected Failure', None):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, 'expected Passed'):
                cases = passed_cases()
                cases[1]['result'] = status
                validate_results(results(cases))

    def test_unexpected_and_duplicate_cases_fail(self):
        for extra, error in (
            (case('testExample'), 'Unexpected native smoke test'),
            (case('testIOSTFLitePhotoPipeline'), 'Duplicate native smoke test'),
        ):
            with self.subTest(extra=extra), self.assertRaisesRegex(ValueError, error):
                validate_results(results([*passed_cases(), extra]))

    def test_unsupported_json_shape_fails(self):
        for document in ({}, {'testNodes': {}}, {'testNodes': [{}]}):
            with self.subTest(document=document), self.assertRaisesRegex(ValueError, 'xcresulttool'):
                validate_results(document)


if __name__ == '__main__':
    unittest.main()
