import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maturity labels are field-readable', () {
    expect(MaturityClass.immature.label, 'Immature');
    expect(MaturityClass.mature.label, 'Mature');
    expect(MaturityClass.overmature.label, 'Overmature');
  });

  test('maturity colors use shared design tokens', () {
    expect(MaturityClass.immature.color, AppConstants.immatureColor);
    expect(MaturityClass.mature.color, AppConstants.matureColor);
    expect(MaturityClass.overmature.color, AppConstants.overmatureColor);
  });
}
