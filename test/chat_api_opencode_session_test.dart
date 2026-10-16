import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/api/provider_request_headers.dart';

class _ProxyHttpOverrides extends HttpOverrides {
  _ProxyHttpOverrides(this.port);

  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    return client;
  }
}

ProviderConfig _config({String host = 'opencode.ai'}) {
  return ProviderConfig(
    id: 'OpenCode',
    enabled: true,
    name: 'OpenCode',
    apiKey: 'test-key',
    baseUrl: 'http://$host/zen/go/v1',
    providerType: ProviderKind.openai,
  );
}

const _reply = {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': 'ok'},
      'finish_reason': 'stop',
    },
  ],
};

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  group('providerSessionHeaders (OpenCode)', () {
    test('only applies to the official opencode.ai host', () {
      for (final host in [
        'example.com',
        'opencode.ai.example.com',
        'fakeopencode.ai',
      ]) {
        expect(
          providerSessionHeaders(_config(host: host), conversationId: 'chat'),
          isNull,
        );
      }
      expect(
        providerSessionHeaders(
          _config(host: 'OPENCODE.AI'),
          conversationId: 'chat',
        ),
        {'x-opencode-session': 'chat'},
      );
    });

    test('generates a stable uuid when conversation id is blank', () {
      final header =
          providerSessionHeaders(
            _config(),
            conversationId: '   ',
          )!['x-opencode-session'];
      expect(header, matches(_uuidV4));
    });

    test('preserves caller extra headers', () {
      expect(
        providerSessionHeaders(
          _config(),
          conversationId: 'chat',
          extraHeaders: const {'X-Conversation-Id': 'chat'},
        ),
        {'x-opencode-session': 'chat', 'X-Conversation-Id': 'chat'},
      );
    });

    test('returns extra headers unchanged for other hosts', () {
      expect(
        providerSessionHeaders(
          _config(host: 'example.com'),
          conversationId: 'chat',
          extraHeaders: const {'X-Conversation-Id': 'chat'},
        ),
        {'X-Conversation-Id': 'chat'},
      );
    });
  });

  group('ChatApiService OpenCode session header', () {
    test('reuses the conversation id as the opencode session', () async {
      final headers = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        headers.add(request.headers.value('x-opencode-session'));
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_reply));
        await request.response.close();
      });

      await HttpOverrides.runZoned(() async {
        for (final id in ['chat-a', 'chat-a', 'chat-b', null]) {
          final result = await ChatApiService.generateText(
            config: _config(),
            modelId: 'test-model',
            prompt: 'hello',
            conversationId: id,
          );
          expect(result, 'ok');
        }
      }, createHttpClient: _ProxyHttpOverrides(server.port).createHttpClient);

      expect(headers.take(3), ['chat-a', 'chat-a', 'chat-b']);
      expect(headers[3], matches(_uuidV4));
    });
  });
}
