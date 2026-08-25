import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maturity labels are field-readable', () {
    expect(MaturityClass.immature.label, 'Immature');
    expect(MaturityClass.mature.label, 'Mature');
    expect(MaturityClass.overmature.label, 'Overmature');
  });
}
