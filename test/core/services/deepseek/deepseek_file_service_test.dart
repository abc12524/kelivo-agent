import 'dart:convert';

import 'package:Kelivo/core/services/deepseek/deepseek_file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('DeepSeekFileService.list', () {
    test('parses file list response', () async {
      final service = DeepSeekFileService(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        client: MockClient((req) async {
          expect(req.method, 'GET');
          expect(req.url.path, '/files');
          expect(req.url.queryParameters['limit'], '100');
          expect(req.url.queryParameters['order'], 'asc');
          expect(req.url.queryParameters['purpose'], 'user_data');
          return http.Response(
            jsonEncode({
              'object': 'list',
              'data': [
                {
                  'id': 'file-api-1',
                  'bytes': 102400,
                  'filename': 'image.jpg',
                  'purpose': 'user_data',
                },
              ],
              'has_more': false,
            }),
            200,
          );
        }),
      );

      final body = await service.list();

      final data = body['data'] as List;
      expect(data, hasLength(1));
      expect((data.first as Map)['id'], 'file-api-1');
    });

    test('throws on non-200 response', () async {
      final service = DeepSeekFileService(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        client: MockClient((_) async => http.Response('unauthorized', 401)),
      );

      expect(() => service.list(), throwsA(isA<StateError>()));
    });
  });

  group('DeepSeekFileService.retrieve', () {
    test('returns file object', () async {
      final service = DeepSeekFileService(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        client: MockClient((req) async {
          expect(req.url.path, '/files/file-api-9');
          return http.Response(
            jsonEncode({
              'id': 'file-api-9',
              'filename': 'a.png',
              'bytes': 10,
            }),
            200,
          );
        }),
      );

      final obj = await service.retrieve('file-api-9');
      expect(obj['id'], 'file-api-9');
    });
  });

  group('DeepSeekFileService.delete', () {
    test('returns true when deleted flag is set', () async {
      final service = DeepSeekFileService(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        client: MockClient((req) async {
          expect(req.method, 'DELETE');
          expect(req.url.path, '/files/file-api-9');
          return http.Response(
            jsonEncode({'id': 'file-api-9', 'object': 'file', 'deleted': true}),
            200,
          );
        }),
      );

      expect(await service.delete('file-api-9'), isTrue);
    });
  });

  group('DeepSeekFileService guards', () {
    test('throws when api key is empty', () async {
      final service = DeepSeekFileService(
        baseUrl: 'https://api.deepseek.com',
        apiKey: '',
        client: MockClient((_) async => http.Response('{}', 200)),
      );

      expect(() => service.list(), throwsA(isA<StateError>()));
    });
  });
}
