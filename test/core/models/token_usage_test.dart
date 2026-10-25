import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/token_usage.dart';

void main() {
  group('TokenUsage', () {
    test(
      'merge preserves explicit total when split token fields are missing',
      () {
        final merged = const TokenUsage().merge(
          const TokenUsage(totalTokens: 895),
        );

        expect(merged.promptTokens, 0);
        expect(merged.completionTokens, 0);
        expect(merged.cachedTokens, 0);
        expect(merged.totalTokens, 895);
      },
    );

    test('add accumulates usage across rounds', () {
      final total = const TokenUsage(
        promptTokens: 100,
        completionTokens: 20,
        cachedTokens: 30,
      ).add(
        const TokenUsage(
          promptTokens: 200,
          completionTokens: 40,
          cachedTokens: 50,
        ),
      );

      expect(total.promptTokens, 300);
      expect(total.completionTokens, 60);
      expect(total.cachedTokens, 80);
      expect(total.totalTokens, 360);
    });
  });
}
