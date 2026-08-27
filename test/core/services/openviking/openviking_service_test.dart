import 'dart:convert';

import 'package:Kelivo/core/services/openviking/openviking_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('OpenVikingService.search', () {
    test('merges memories/resources/skills segments and sorts by score desc', () async {
      final service = OpenVikingService(
        baseUrl: 'http://ov.local',
        apiKey: 'key',
        user: 'u',
        client: MockClient((_) async {
          return http.Response(
            jsonEncode({
              'result': {
                'memories': [
                  {'uri': 'viking://m/1', 'score': 0.5, 'abstract': 'mem', 'category': 'preferences'},
                ],
                'resources': [
                  {'uri': 'viking://r/1', 'score': 0.9, 'abstract': 'res', 'category': 'doc'},
                ],
                'skills': [
                  {'uri': 'viking://s/1', 'score': 0.7, 'abstract': 'skill', 'category': 'tool'},
                ],
              },
            }),
            200,
          );
        }),
      );

      final result = await service.search('q');

      // 三段合并，三段各自一条
      expect(result.hits, hasLength(3));
      // 按相关度降序：resource(0.9) > skill(0.7) > memory(0.5)
      expect(result.hits[0].uri, 'viking://r/1');
      expect(result.hits[1].uri, 'viking://s/1');
      expect(result.hits[2].uri, 'viking://m/1');
    });

    test('dedups by uri across segments', () async {
      final service = OpenVikingService(
        baseUrl: 'http://ov.local',
        apiKey: 'key',
        user: 'u',
        client: MockClient((_) async {
          return http.Response(
            jsonEncode({
              'result': {
                'memories': [
                  {'uri': 'viking://dup', 'score': 0.8, 'abstract': 'mem', 'category': 'preferences'},
                ],
                'resources': [
                  {'uri': 'viking://dup', 'score': 0.3, 'abstract': 'res', 'category': 'doc'},
                ],
              },
            }),
            200,
          );
        }),
      );

      final result = await service.search('q');
      // 同 uri 只保留首次出现的一条
      expect(result.hits, hasLength(1));
      expect(result.hits.single.uri, 'viking://dup');
    });

    test('returns empty when no segment has hits', () async {
      final service = OpenVikingService(
        baseUrl: 'http://ov.local',
        apiKey: 'key',
        user: 'u',
        client: MockClient((_) async {
          return http.Response(jsonEncode({'result': {'memories': []}}), 200);
        }),
      );

      final result = await service.search('q');
      expect(result.hits, isEmpty);
    });
  });
}
