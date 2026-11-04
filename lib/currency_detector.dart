import 'dart:developer' as dev;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class Recognition {
  final String label;
  final double score;
  final Rect location;
  Recognition(this.label, this.score, this.location);

  @override
  String toString() => '$label (${(score * 100).toStringAsFixed(1)}%)';
}

const Set<int> kenyanCurrencyDenominations = {
  5,
  10,
  20,
  50,
  100,
  200,
  500,
  1000
};

int? parseKenyanDenomination(String label) {
  final normalized = label.trim().replaceAll(',', '');
  final amount = int.tryParse(normalized);
  return kenyanCurrencyDenominations.contains(amount) ? amount : null;
}

int? readKenyanNoteDenomination(String recognizedText) {
  final pattern = RegExp(r'\b(1000|500|200|100|50|20|10|5)\b');
  final counts = <int, int>{};
  for (final match in pattern.allMatches(recognizedText)) {
    final amount = int.parse(match.group(1)!);
    counts.update(amount, (count) => count + 1, ifAbsent: () => 1);
  }
  if (counts.isEmpty) return null;

  final mostFrequentCount = counts.values.reduce((a, b) => a > b ? a : b);
  if (mostFrequentCount < 2) return null;
  final winners =
      counts.entries.where((entry) => entry.value == mostFrequentCount);
  return winners.length == 1 ? winners.single.key : null;
}

int? selectKenyanDenomination({
  required List<Recognition> recognitions,
  required int? ocrDenomination,
  required double minimumConfidence,
}) {
  final modelDenomination =
      recognitions.isNotEmpty && recognitions.first.score >= minimumConfidence
          ? parseKenyanDenomination(recognitions.first.label)
          : null;

  if (ocrDenomination != null) {
    if (modelDenomination != null && modelDenomination != ocrDenomination) {
      return null;
    }
    return ocrDenomination;
  }
  return modelDenomination;
}

class CurrencyDetector {
  Interpreter? _interpreter;
  List<String> labels = [];
  int inputSize = 224;

  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions();
      if (Platform.isAndroid) {
        try {
          options.addDelegate(GpuDelegateV2());
        } catch (_) {}
      } else if (Platform.isIOS) {
        try {
          options.addDelegate(GpuDelegate());
        } catch (_) {}
      }

      try {
        _interpreter = await Interpreter.fromAsset(
            'assets/currency_model.tflite',
            options: options);
      } catch (_) {
        _interpreter =
            await Interpreter.fromAsset('assets/currency_model.tflite');
      }

      final inputShape = _interpreter!.getInputTensor(0).shape;
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      if (inputShape.length >= 3) inputSize = inputShape[1];
      dev.log('CurrencyDetector: input=$inputShape  output=$outputShape');

      final labelsData = await rootBundle.loadString('assets/labels.txt');
      labels = labelsData
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      dev.log('CurrencyDetector: ${labels.length} labels → $labels');
    } catch (e) {
      dev.log('CurrencyDetector: loadModel error — $e');
      rethrow;
    }
  }

  Future<List<Recognition>> predict(File imageFile) async {
    if (_interpreter == null) await loadModel();

    final bytes = await imageFile.readAsBytes();

    final Float32List inputBuffer = await compute(_preprocessImage, {
      'bytes': bytes,
      'inputSize': inputSize,
    });

    if (inputBuffer.isEmpty) throw Exception('Image preprocessing failed');

    final input = inputBuffer.reshape([1, inputSize, inputSize, 3]);
    final output = List.filled(labels.length, 0.0).reshape([1, labels.length]);

    _interpreter!.run(input, output);

    final List<Recognition> results = [];
    for (int i = 0; i < labels.length; i++) {
      final double score = (output[0][i] as num).toDouble();
      if (score >= 0.05) {
        // Since this is a classification model, we provide a dummy rect
        // that covers the detection area (e.g., the center of the frame).
        // Coordinates are normalized between 0.0 and 1.0.
        const location = Rect.fromLTWH(0.1, 0.1, 0.8, 0.8);
        results.add(Recognition(labels[i], score, location));
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    dev.log('CurrencyDetector: $results');
    return results;
  }

  // YOUR ORIGINAL MODEL expects raw 0-255 float32 values.
  // EfficientNetB0 handles normalisation internally — do NOT divide or subtract here.
  static Float32List _preprocessImage(Map<String, dynamic> args) {
    final Uint8List bytes = args['bytes'];
    final int inputSize = args['inputSize'];

    img.Image? image = img.decodeImage(bytes);
    if (image == null) return Float32List(0);

    // 1. Fix orientation (Exif) so the model doesn't see the image sideways
    image = img.bakeOrientation(image);

    // Keep the entire note in frame instead of cropping its ends.
    final resized = img.copyResize(
      image,
      width: inputSize,
      height: inputSize,
      maintainAspect: true,
      backgroundColor: img.ColorRgb8(128, 128, 128),
      interpolation: img.Interpolation.linear,
    );

    final buffer = Float32List(inputSize * inputSize * 3);
    var offset = 0;
    for (final pixel in resized) {
      // Reverting to raw 0-255 values as the model expects raw float32 inputs
      buffer[offset++] = pixel.r.toDouble();
      buffer[offset++] = pixel.g.toDouble();
      buffer[offset++] = pixel.b.toDouble();
    }
    return buffer;
  }

  void close() => _interpreter?.close();
}
