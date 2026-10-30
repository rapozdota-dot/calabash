import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';

/// Dependency-free OOXML export for the mobile recorder. Called in its export
/// isolate, never inside a measured inference or on every live camera frame.
class PerformanceWorkbook {
  PerformanceWorkbook._();

  static List<int> create(String rawCsv, String summaryCsv, String metadata) {
    final raw = parseCsv(rawCsv);
    final summary = parseCsv(summaryCsv);
    final info = jsonDecode(metadata) as Map<String, dynamic>;
    if (raw.length < 2 || summary.isEmpty) {
      throw StateError('No measurements available for Excel export.');
    }
    if (raw.length > 1048576) {
      throw StateError('Session exceeds the Excel worksheet row limit.');
    }
    final methods = <String, Map<String, String>>{};
    for (final row in summary.skip(1)) {
      final values = Map.fromIterables(summary.first, row);
      methods[values['scanning_method']!] = values;
    }
    final rows = <List<Object?>>[
      ['Calabash Application Performance'],
      ['Model variant', info['model_variant'] ?? 'Not specified'],
      ['Session', info['session_id']],
      ['Model SHA-256', info['model_sha256']],
      ['All durations are milliseconds. Blank means not measured, not zero.'],
      ['Metric', 'Live', 'Gallery', 'Capture', 'Units / Interpretation'],
    ];
    for (final field in summary.first.skip(2)) {
      rows.add([
        _label(field),
        for (final method in ['Live', 'Gallery', 'Capture'])
          _numberOrText(methods[method]?[field] ?? '', numeric: true),
        _notes(field),
      ]);
    }
    final session = <List<Object?>>[
      ['Session Metadata', 'Value'],
      for (final entry in info.entries)
        [
          entry.key,
          entry.value is Map || entry.value is List
              ? jsonEncode(entry.value)
              : entry.value,
        ],
      ['Average application memory', 'Not measured'],
      [
        'Memory snapshot',
        'device_details.app_pss_kb_at_export is a single export-time snapshot, not an average.',
      ],
      [
        'Pure neural execution',
        'interpreter_invoke_ms: Interpreter.invoke() only; excludes tensor transfer.',
      ],
      [
        'Legacy inference boundary',
        'yolo_inference_ms: input tensor transfer + invoke + output tensor transfer.',
      ],
      [
        'Complete photo processing',
        'App analysis start to result prepared; includes file read/decode, model init if needed, preprocessing, inference and masks. Excludes picker/camera interaction and screen rendering.',
      ],
      [
        'Complete live processing',
        'Accepted frame processing through prepared detections, including measured conversion/queue/transfer stages. Excludes waiting for camera frames and screen rendering.',
      ],
      [
        'Processed FPS',
        'Processed inference throughput, not camera preview/rendering FPS.',
      ],
      [
        'Exclusions',
        'Warm-up/errors/invalid timings excluded from relevant summaries. Completed stale/invalidated neural runs remain in inference summaries. All rows retained in Raw Measurements.',
      ],
      [
        'Percentiles',
        'Per-method nearest-rank percentiles from a reservoir of at most 4096 valid inference measurements; sampled, not guaranteed exact full-session percentiles.',
      ],
      [
        'Requirement rule',
        'App reports PASS only after at least 30 valid measurements with every applicable measured duration <=3000 ms. NOT_ENOUGH_DATA is not PASS.',
      ],
      [
        'Accuracy',
        'This workbook measures app speed, not species correctness or maturity accuracy.',
      ],
    ];
    final device = info['device_details'];
    if (device is Map) {
      session.insertAll(1, [
        ['Phone model', device['model'] ?? 'Not measured'],
        ['Manufacturer', device['manufacturer'] ?? 'Not measured'],
        ['Android version', device['android_version'] ?? 'Not measured'],
        ['App version', device['app_version_name'] ?? 'Not measured'],
        [
          'Installed version code',
          device['app_version_code'] ?? 'Not measured',
        ],
        ['Chipset / hardware', device['processor'] ?? 'Not measured'],
        [
          'Kernel-accessible RAM (GiB)',
          device['ram_total_bytes_kernel_accessible'] is num
              ? (device['ram_total_bytes_kernel_accessible'] as num) /
                    1073741824
              : 'Not measured',
        ],
        [
          'App PSS at export (MiB)',
          device['app_pss_kb_at_export'] is num
              ? (device['app_pss_kb_at_export'] as num) / 1024
              : 'Not measured',
        ],
      ]);
    }
    final sheets = [
      ('Summary', _sheet(rows, headerRow: 6, widths: [54, 23, 23, 23, 67])),
      (
        'Raw Measurements',
        _sheet(
          [
            raw.first,
            for (final row in raw.skip(1))
              [
                for (var i = 0; i < row.length; i++)
                  _numberOrText(row[i], numeric: _numericField(raw.first[i])),
              ],
          ],
          headerRow: 1,
          widths: [
            for (final name in raw.first)
              name == 'model_configuration' || name == 'model_sha256' ? 70 : 25,
          ],
          filter: true,
        ),
      ),
      ('Session', _sheet(session, headerRow: 1, widths: [42, 115])),
    ];
    final archive = Archive();
    void add(String name, String xml) =>
        archive.addFile(ArchiveFile.string(name, xml));
    add(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
          '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
          '${List.generate(sheets.length, (i) => '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>').join()}'
          '</Types>',
    );
    add(
      '_rels/.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    );
    add(
      'xl/workbook.xml',
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
          '${List.generate(sheets.length, (i) => '<sheet name="${sheets[i].$1}" sheetId="${i + 1}" r:id="rId${i + 1}"/>').join()}'
          '</sheets></workbook>',
    );
    add(
      'xl/_rels/workbook.xml.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '${List.generate(sheets.length, (i) => '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>').join()}'
          '<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
    );
    add('xl/styles.xml', _styles);
    for (var i = 0; i < sheets.length; i++) {
      add('xl/worksheets/sheet${i + 1}.xml', sheets[i].$2);
    }
    return ZipEncoder().encode(archive);
  }

  /// RFC4180-style quoted cells, including escaped quotes and embedded newlines.
  static List<List<String>> parseCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    var cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (c == '"') {
        if (quoted && i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (c == ',' && !quoted) {
        row.add(cell.toString());
        cell = StringBuffer();
      } else if ((c == '\r' || c == '\n') && !quoted) {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString());
        rows.add(row);
        row = [];
        cell = StringBuffer();
      } else {
        cell.write(c);
      }
    }
    if (quoted) throw const FormatException('Unclosed CSV quoted field.');
    if (row.isNotEmpty || cell.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    if (rows.isNotEmpty && rows.any((r) => r.length != rows.first.length)) {
      throw const FormatException('CSV rows have inconsistent column counts.');
    }
    return rows;
  }

  static bool _numericField(String name) =>
      name.endsWith('_ms') ||
      name.endsWith('_fps') ||
      name.endsWith('_percent') ||
      const [
        'image_width',
        'image_height',
        'frame_id',
        'detection_count',
        'schema_version',
        'successful_runs',
      ].contains(name);

  static Object? _numberOrText(String text, {required bool numeric}) {
    if (text.isEmpty) return null;
    final value = numeric ? num.tryParse(text) : null;
    return value != null && value.isFinite ? value : text;
  }

  static String _label(String field) => field
      .replaceAll('_', ' ')
      .replaceAll('yolo inference', 'model inference (incl. transfer)')
      .replaceAll('interpreter invoke', 'pure interpreter invoke');

  static String _notes(String field) {
    if (field.contains('requirement')) {
      return '30 valid samples; all <=3000 ms. See Session.';
    }
    if (field.startsWith('sampled_')) return 'ms; sampled reservoir percentile';
    if (field.endsWith('_ms')) return 'ms; blank = not measured';
    if (field.endsWith('_fps')) {
      return 'processed inferences/second, not preview FPS';
    }
    if (field.endsWith('_percent')) return 'percent, 0-100';
    return 'count / status; see Session for exclusion rules';
  }

  static String _column(int index) {
    var result = '';
    var n = index + 1;
    while (n > 0) {
      n--;
      result = String.fromCharCode(65 + n % 26) + result;
      n ~/= 26;
    }
    return result;
  }

  static String _xml(Object? value) => const HtmlEscape().convert(
    (value?.toString() ?? '').replaceAll(
      RegExp('[\x00-\x08\x0B\x0C\x0E-\x1F]'),
      '',
    ),
  );

  static String _sheet(
    List<List<Object?>> rows, {
    required int headerRow,
    required List<double> widths,
    bool filter = false,
  }) {
    final output = StringBuffer(
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<sheetViews><sheetView workbookViewId="0"><pane ySplit="$headerRow" topLeftCell="A${headerRow + 1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
      '<sheetFormatPr defaultRowHeight="30"/><cols>',
    );
    for (var i = 0; i < widths.length; i++) {
      output.write(
        '<col min="${i + 1}" max="${i + 1}" width="${widths[i]}" customWidth="1"/>',
      );
    }
    output.write('</cols><sheetData>');
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final isHeader = i + 1 == headerRow;
      var height = isHeader && filter
          ? 75.0
          : (i + 1 < headerRow ? 30.0 : 46.0);
      for (var c = 0; c < row.length; c++) {
        final lines = (row[c]?.toString() ?? '')
            .split('\n')
            .fold<int>(
              0,
              (count, line) =>
                  count + math.max(1, (line.length / (widths[c] * .85)).ceil()),
            );
        height = math.max(height, math.min(360, lines * 15 + 8).toDouble());
      }
      output.write('<row r="${i + 1}" ht="$height" customHeight="1">');
      for (var c = 0; c < row.length; c++) {
        final value = row[c];
        final ref = '${_column(c)}${i + 1}';
        final style = isHeader || (i == 0 && headerRow > 1)
            ? 1
            : value is int
            ? 4
            : value is num
            ? 3
            : i.isEven
            ? 2
            : 0;
        if (value == null) {
          output.write('<c r="$ref" s="$style"/>');
          continue;
        }
        if (value is num && value.isFinite) {
          output.write('<c r="$ref" s="$style"><v>$value</v></c>');
        } else {
          // Inline strings cannot execute formulas from user/device CSV text.
          final text = value.toString();
          output.write(
            '<c r="$ref" s="$style" t="inlineStr"><is><t xml:space="preserve">${_xml(text.substring(0, math.min(text.length, 32767)))}</t></is></c>',
          );
        }
      }
      output.write('</row>');
    }
    output.write('</sheetData>');
    if (filter) {
      output.write(
        '<autoFilter ref="A$headerRow:${_column(widths.length - 1)}${rows.length}"/>',
      );
    }
    if (headerRow > 1) {
      output.write(
        '<mergeCells count="5"><mergeCell ref="A1:E1"/><mergeCell ref="B2:E2"/><mergeCell ref="B3:E3"/><mergeCell ref="B4:E4"/><mergeCell ref="A5:E5"/></mergeCells>',
      );
    }
    output.write('</worksheet>');
    return output.toString();
  }

  static const _styles =
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<numFmts count="1"><numFmt numFmtId="164" formatCode="0.000"/></numFmts>'
      '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="12"/><name val="Calibri"/></font></fonts>'
      '<fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF2E7D32"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF0F5EE"/><bgColor indexed="64"/></patternFill></fill></fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>'
      '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1" applyFill="1" applyFont="1"><alignment vertical="center" wrapText="1"/></xf>'
      '<xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyAlignment="1" applyFill="1"><alignment vertical="top" wrapText="1"/></xf>'
      '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment vertical="top"/></xf>'
      '<xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment vertical="top"/></xf></cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>';
}
