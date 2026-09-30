import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'journal.dart';

const _prefix = 'evantube-playlists-v1-';

class EvanDriveTransport {
  final http.Client client;
  final Future<Map<String, String>> Function() authorization;
  EvanDriveTransport(this.client, this.authorization);
  final files = <Map<String, dynamic>>[];

  Future<List<int>> _request(String method, Uri uri,
      {List<int>? body,
      String? contentType,
      int limit = journalByteLimit}) async {
    return (() async {
      final request = http.Request(method, uri)..followRedirects = false;
      request.headers.addAll(await authorization());
      if (contentType != null) request.headers['Content-Type'] = contentType;
      if (body != null) request.bodyBytes = body;
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
            'Google Drive request failed (${response.statusCode}). Retry or reconnect.');
      }
      if ((response.contentLength ?? 0) > limit)
        throw const FormatException('Drive response is too large.');
      final bytes = <int>[];
      await for (final part in response.stream) {
        if (bytes.length + part.length > limit)
          throw const FormatException('Drive response is too large.');
        bytes.addAll(part);
      }
      return bytes;
    })()
        .timeout(const Duration(seconds: 30));
  }

  Future<List<List<Map<String, dynamic>>>> download() async {
    files.clear();
    String? token;
    final seenTokens = <String>{};
    do {
      final bytes = await _request(
          'GET',
          Uri.https('www.googleapis.com', '/drive/v3/files', {
            'spaces': 'appDataFolder',
            'q': "trashed = false and name contains '$_prefix'",
            'fields': 'nextPageToken,files(id,name)',
            'pageSize': '100',
            if (token != null) 'pageToken': token,
          }),
          limit: 256 * 1024);
      final page = jsonDecode(utf8.decode(bytes));
      if (page is! Map || page['files'] is! List)
        throw const FormatException('Invalid Drive file list.');
      for (final raw in page['files']) {
        if (raw is! Map ||
            raw['id'] is! String ||
            raw['name'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(raw['id']))
          throw const FormatException('Invalid Drive file.');
        if (!(raw['name'] as String).startsWith(_prefix) ||
            !(raw['name'] as String).endsWith('.json')) continue;
        files.add(Map<String, dynamic>.from(raw));
        if (files.length > 128)
          throw const FormatException('More than 128 EvanTube journals.');
      }
      token = page['nextPageToken'] as String?;
      if (token != null && (!seenTokens.add(token) || seenTokens.length > 128))
        throw const FormatException('Invalid Drive pagination.');
    } while (token != null && token.isNotEmpty);
    var total = 0;
    final journals = <List<Map<String, dynamic>>>[];
    for (final file in files) {
      final bytes = await _request(
          'GET',
          Uri.https(
              'www.googleapis.com',
              '/drive/v3/files/${Uri.encodeComponent(file['id'])}',
              {'alt': 'media'}));
      total += bytes.length;
      if (total > 20 * 1024 * 1024)
        throw const FormatException('EvanTube download exceeds 20 MiB.');
      journals.add(decodeJournal(bytes));
    }
    return journals;
  }

  Future<void> upload(String device, List<int> bytes) async {
    if (!RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(device)) {
      throw const FormatException('Invalid Drive writer identity.');
    }
    final name = '$_prefix$device.json';
    final own = files.where((f) => f['name'] == name).toList()
      ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    if (own.isNotEmpty) {
      await _request(
          'PATCH',
          Uri.https(
              'www.googleapis.com',
              '/upload/drive/v3/files/${Uri.encodeComponent(own.first['id'])}',
              {'uploadType': 'media'}),
          body: bytes,
          contentType: 'application/json');
    } else {
      final boundary = 'evantube_${const Uuid().v4()}';
      final metadata = jsonEncode({
        'name': name,
        'mimeType': 'application/json',
        'parents': ['appDataFolder']
      });
      final body = <int>[
        ...utf8.encode(
            '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: application/json\r\n\r\n'),
        ...bytes,
        ...utf8.encode('\r\n--$boundary--\r\n')
      ];
      await _request(
          'POST',
          Uri.https('www.googleapis.com', '/upload/drive/v3/files',
              {'uploadType': 'multipart', 'fields': 'id'}),
          body: body,
          contentType: 'multipart/related; boundary=$boundary');
    }
  }
}
