"""Select an iOS simulator and verify native smoke-test results for CI."""

import argparse
import json
from pathlib import Path
import re
import sys
from typing import NamedTuple


class Simulator(NamedTuple):
    name: str
    udid: str
    state: str
    version: tuple[int, ...]


IOS_RUNTIME = re.compile(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)(?:-(\d+))?(?:-(\d+))?')
SIMULATOR_UDID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', re.IGNORECASE)

# FLTIntegrationTestRunner capitalizes the Dart names, drops non-alphanumeric
# characters and prefixes "test" when constructing the XCTest selectors.
EXPECTED_TESTS = {
    'testiosfluttertestrunnerstartup': 'iOS Flutter test runner startup',
    'testiostflitephotopipeline': 'iOS TFLite photo pipeline',
    'testiostfliteliveworkerpipeline': 'iOS TFLite live worker pipeline',
}


def select_simulator(document):
    devices = document.get('devices') if isinstance(document, dict) else None
    if not isinstance(devices, dict):
        raise ValueError('simctl output is missing the devices object.')

    phones = []
    for runtime, entries in devices.items():
        match = IOS_RUNTIME.fullmatch(runtime)
        if not match:
            continue
        if not isinstance(entries, list):
            raise ValueError(f'simctl device entries for {runtime} are not a list.')
        version = tuple(int(part or 0) for part in match.groups())
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError(f'Invalid simctl device entry for {runtime}.')
            name = entry.get('name')
            if (entry.get('isAvailable') is not True
                    or not isinstance(name, str) or not name.startswith('iPhone')):
                continue
            udid = entry.get('udid')
            state = entry.get('state')
            if not isinstance(udid, str) or not SIMULATOR_UDID.fullmatch(udid):
                raise ValueError(f'Available iPhone {name!r} has an invalid simulator UDID.')
            if not isinstance(state, str) or not state:
                raise ValueError(f'Available iPhone {name!r} is missing its simulator state.')
            phones.append(Simulator(name, udid, state, version))

    if not phones:
        raise ValueError('No available iPhone simulator found. Native model validation is required.')

    return min(phones, key=lambda phone: (
        phone.state != 'Booted',
        tuple(-part for part in phone.version),
        phone.name.casefold(),
        phone.udid.casefold(),
    ))


def test_cases(nodes):
    if not isinstance(nodes, list):
        raise ValueError('xcresulttool test nodes must be a list.')
    for node in nodes:
        if not isinstance(node, dict) or not isinstance(node.get('nodeType'), str):
            raise ValueError('xcresulttool returned a test node without a valid nodeType.')
        if node['nodeType'] == 'Test Case':
            yield node
        yield from test_cases(node.get('children', []))


def validate_results(document):
    if not isinstance(document, dict) or 'testNodes' not in document:
        raise ValueError('xcresulttool output is missing the testNodes tree.')

    observed = set()
    for case in test_cases(document['testNodes']):
        identifier = case.get('nodeIdentifier', case.get('name'))
        if not isinstance(identifier, str) or not identifier:
            raise ValueError('xcresulttool returned an unnamed Test Case.')
        selector = identifier.rsplit('/', 1)[-1].removesuffix('()').casefold()
        if selector not in EXPECTED_TESTS:
            raise ValueError(f'Unexpected native smoke test {identifier!r}.')
        if selector in observed:
            raise ValueError(f'Duplicate native smoke test {identifier!r}.')
        result = case.get('result')
        if result != 'Passed':
            raise ValueError(f'Native smoke test {identifier!r} reported {result!r}, expected Passed.')
        observed.add(selector)

    missing = [name for selector, name in EXPECTED_TESTS.items() if selector not in observed]
    if missing:
        raise ValueError(f'Missing required native smoke tests: {", ".join(missing)}.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    simulator = commands.add_parser('select-simulator', help='select a simulator from simctl device JSON')
    simulator.add_argument('path', type=Path)
    results = commands.add_parser('validate-results', help='verify all required xcresulttool test cases')
    results.add_argument('path', type=Path)
    args = parser.parse_args()
    try:
        document = json.loads(args.path.read_text(encoding='utf-8'))
        if args.command == 'select-simulator':
            simulator = select_simulator(document)
            version = '.'.join(map(str, simulator.version))
            print(
                f'Selected {simulator.name} ({simulator.udid}), iOS {version}, state {simulator.state}.',
                file=sys.stderr,
            )
            print(simulator.udid)
        else:
            validate_results(document)
            print(f'Confirmed all {len(EXPECTED_TESTS)} required native iOS smoke tests passed.')
    except (OSError, ValueError) as error:
        parser.exit(1, f'{args.command}: {error}\n')


if __name__ == '__main__':
    main()
