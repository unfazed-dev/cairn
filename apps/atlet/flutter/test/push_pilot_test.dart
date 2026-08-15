import 'package:flutter_test/flutter_test.dart';
import 'package:atlet/push/push_pilot.dart';

/// Pure-logic check for the doorbell routing decision — the only non-Firebase
/// behavior in the pilot module (everything else needs a live FCM rail).
void main() {
  group('isCairnDoorbell', () {
    test('accepts a cairn doorbell payload {table, lsn}', () {
      expect(isCairnDoorbell({'table': 'sessions', 'lsn': '0/1A2B3C'}), isTrue);
    });

    test('rejects payloads missing either key', () {
      expect(isCairnDoorbell({'table': 'sessions'}), isFalse);
      expect(isCairnDoorbell({'lsn': '0/1A2B3C'}), isFalse);
      expect(isCairnDoorbell(<String, dynamic>{}), isFalse);
    });

    test('rejects null and non-doorbell messages', () {
      expect(isCairnDoorbell(null), isFalse);
      expect(
        isCairnDoorbell({'notification': {'title': 'sale'}}),
        isFalse,
      );
    });
  });
}
