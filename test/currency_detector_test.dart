import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:stockipa/currency_detector.dart';

void main() {
  group('Kenyan currency recognition', () {
    test('accepts only configured denomination labels', () {
      expect(parseKenyanDenomination(' 1000 '), 1000);
      expect(parseKenyanDenomination('500'), 500);
      expect(parseKenyanDenomination('KSh 500'), isNull);
      expect(parseKenyanDenomination('250'), isNull);
      expect(parseKenyanDenomination(''), isNull);
    });

    test('requires repeated, unambiguous OCR denomination evidence', () {
      expect(readKenyanNoteDenomination('Serial 500921'), isNull);
      expect(readKenyanNoteDenomination('500 500'), 500);
      expect(readKenyanNoteDenomination('500 500 1000 1000'), isNull);
      expect(readKenyanNoteDenomination('20 20'), 20);
    });

    test('uses OCR as fallback and rejects conflicting strong results', () {
      final recognitions = [
        Recognition('500', 0.4, Rect.zero),
        Recognition('100', 0.2, Rect.zero),
      ];

      expect(
        selectKenyanDenomination(
          recognitions: recognitions,
          ocrDenomination: 500,
          minimumConfidence: 0.25,
        ),
        500,
      );
      expect(
        selectKenyanDenomination(
          recognitions: recognitions,
          ocrDenomination: 100,
          minimumConfidence: 0.25,
        ),
        isNull,
      );
      expect(
        selectKenyanDenomination(
          recognitions: const [],
          ocrDenomination: 20,
          minimumConfidence: 0.25,
        ),
        20,
      );
    });
  });
}
