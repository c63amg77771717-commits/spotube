import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../lib/services/evantube/drive_transport.dart';
import '../lib/services/evantube/journal.dart';

void main() {
  final fixture =
      File('test/fixtures/evantube_drive_v1.json').readAsStringSync();
  const writer = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  test('all pages downloaded; upload updates only this installation journal',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'PATCH') {
        expect(request.url.path, '/upload/drive/v3/files/own');
        expect(decodeJournal(request.bodyBytes), isEmpty);
        return http.Response('{}', 200);
      }
      if (request.url.queryParameters['alt'] == 'media')
        return http.Response(fixture, 200);
      expect(request.url.queryParameters['spaces'], 'appDataFolder');
      return http.Response(
          jsonEncode(request.url.queryParameters['pageToken'] == null
              ? {
                  'nextPageToken': 'second',
                  'files': [
                    {'id': 'other', 'name': 'evantube-playlists-v1-other.json'}
                  ]
                }
              : {
                  'files': [
                    {'id': 'own', 'name': 'evantube-playlists-v1-$writer.json'}
                  ]
                }),
          200);
    });
    final transport = EvanDriveTransport(client, () async => {});
    expect((await transport.download()).length, 2);
    await transport.upload(writer, encodeJournal([]));
    expect(requests.where((r) => r.method == 'PATCH').length, 1);
    expect(
        requests.where((r) => r.url.queryParameters['alt'] == 'media').length,
        2);
  });
  test('new installation creates appData file, malformed pagination aborts',
      () async {
    final transport = EvanDriveTransport(MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.queryParameters['uploadType'], 'multipart');
      expect(request.body, contains('"parents":["appDataFolder"]'));
      expect(request.body, contains('evantube-playlists-v1-$writer.json'));
      return http.Response('{"id":"new"}', 200);
    }), () async => {});
    await transport.upload(writer, encodeJournal([]));
    final broken = EvanDriveTransport(
        MockClient((_) async =>
            http.Response('{"files":[],"nextPageToken":"repeat"}', 200)),
        () async => {});
    await expectLater(broken.download(), throwsFormatException);
  });
  test('non-2xx, oversized bodies and invalid remote schema fail closed',
      () async {
    final denied = EvanDriveTransport(
        MockClient((_) async => http.Response('denied', 403)), () async => {});
    await expectLater(denied.download(), throwsA(isA<HttpException>()));
    final large = EvanDriveTransport(
        MockClient((_) async => http.Response('x' * (256 * 1024 + 1), 200)),
        () async => {});
    await expectLater(large.download(), throwsFormatException);
    final malformed = EvanDriveTransport(
        MockClient((request) async => http.Response(
            request.url.queryParameters['alt'] == 'media'
                ? '{"schemaVersion":99,"events":[]}'
                : '{"files":[{"id":"bad","name":"evantube-playlists-v1-bad.json"}]}',
            200)),
        () async => {});
    await expectLater(malformed.download(), throwsFormatException);
  });
}
