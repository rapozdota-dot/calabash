import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:calabash_maturity_detection/services/performance_workbook.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CSV parser handles quoted commas, quotes and embedded newlines', () {
    expect(
      PerformanceWorkbook.parseCsv('a,b\r\n"first, second","a""b\nc"\r\n'),
      [
        ['a', 'b'],
        ['first, second', 'a"b\nc'],
      ],
    );
    expect(
      () => PerformanceWorkbook.parseCsv('a,b\n"bad'),
      throwsFormatException,
    );
    expect(() => PerformanceWorkbook.parseCsv('a,b\na'), throwsFormatException);
  });

  test(
    'Excel has typed timings, text-safe source data, and blank missing metrics',
    () async {
      final bytes = PerformanceWorkbook.create(
        'measurement_id,yolo_inference_ms,interpreter_invoke_ms,model_configuration,model_sha256\r\n'
            '001,12.345,,"=HYPERLINK(""bad"")",1e30\r\n',
        'session_id,scanning_method,total_measurements,average_yolo_inference_ms,average_interpreter_invoke_ms\r\n'
            'synthetic,Live,1,12.345,\r\n'
            'synthetic,Gallery,0,,\r\n'
            'synthetic,Capture,0,,\r\n',
        jsonEncode({
          'session_id': 'SYNTHETIC QA FIXTURE - NOT DEVICE RESULTS',
          'model_variant': 'Test & <variant>',
          'model_sha256': '1e30',
        }),
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      String xml(String path) =>
          utf8.decode(archive.findFile(path)!.content as List<int>);
      expect(xml('xl/workbook.xml'), contains('name="Summary"'));
      expect(xml('xl/workbook.xml'), contains('name="Raw Measurements"'));
      expect(xml('xl/workbook.xml'), contains('name="Session"'));
      final raw = xml('xl/worksheets/sheet2.xml');
      expect(raw, contains('<v>12.345</v>'));
      expect(raw, contains('>001</t>'));
      expect(raw, contains('>1e30</t>'));
      expect(raw, contains('=HYPERLINK'));
      expect(raw, isNot(contains('<f>')));
      expect(raw, contains('autoFilter'));
      expect(raw, contains('state="frozen"'));
      final summary = xml('xl/worksheets/sheet1.xml');
      expect(summary, contains('Test &amp; &lt;variant&gt;'));
      expect(summary, contains('Blank means not measured'));
      expect(xml('xl/worksheets/sheet3.xml'), contains('Not measured'));
      // A generated test artifact for independent reader/rendering QA, not results.
      await Directory('tmp/performance-export-qa').create(recursive: true);
      await File(
        'tmp/performance-export-qa/synthetic-fixture.xlsx',
      ).writeAsBytes(bytes);
    },
  );

  test('empty measurements never become an invented workbook', () {
    expect(
      () => PerformanceWorkbook.create('a,b\r\n', 'a,b\r\n', '{}'),
      throwsStateError,
    );
  });
}
