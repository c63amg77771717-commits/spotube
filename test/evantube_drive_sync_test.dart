import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../lib/services/evantube/journal.dart';
import '../lib/services/evantube/library_store.dart';

void main() {
  final fixture =
      File('test/fixtures/evantube_drive_v1.json').readAsBytesSync();
  final events = decodeJournal(fixture);
  test('unique event limit and nonempty whitespace title match Swift', () {
    final duplicate = {...events.first, 'title': ' '};
    expect(
        decodeJournal(encodeJournal(List.filled(20001, duplicate))).length, 1);
  });
  test('merged persisted size is checked before upload and application',
      () async {
    final store = EvanLibraryStore(File('unused'), saveOverride: (_) async {});
    await store.activate('account');
    final largeThumbnail = 'x' * (4 * 1024 * 1024 + 500000);
    final remote = List.generate(
        6,
        (index) => <Map<String, dynamic>>[
              {
                'id':
                    '00000000-0000-0000-0000-${(index + 101).toString().padLeft(12, '0')}',
                'deviceId': 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
                'clock': index + 1,
                'kind': 'putSong',
                'playlistId': 'unknown',
                'song': {
                  'youtubeId': 'aaaaaaaaaaa',
                  'title': '',
                  'artist': '',
                  'duration': 0,
                  'thumbnailURL': largeThumbnail
                }
              }
            ]);
    await store.sync(
        'account', () async => remote.take(4).toList(), (_, __) async {});
    final previousSync = store.lastSync;
    var uploaded = false;
    await expectLater(
        store.sync('account', () async => remote.skip(4).toList(),
            (_, __) async {
          uploaded = true;
        }),
        throwsFormatException);
    expect(uploaded, isFalse);
    expect(store.events.length, 4);
    expect(store.lastSync, previousSync);
  });
  test(
      'Swift/Dart fixture converges independently of order and duplicate delivery',
      () {
    expect(events.length, 12);
    final replay = replayJournal([...events.reversed, ...events]);
    expect(replay.map((p) => p.id), ['p2', 'p1']);
    expect(replay.map((p) => p.title), ['Second', 'Renamed']);
    expect(replay.first.songs, isEmpty);
    expect(replay.last.songs.map((s) => s['youtubeId']),
        ['bbbbbbbbbbb', 'aaaaaaaaaaa']);
  });
  test(
      'unknown schema, unknown keys, bad IDs and conflicting duplicates fail closed',
      () {
    expect(() => decodeJournal(utf8.encode('{"schemaVersion":2,"events":[]}')),
        throwsFormatException);
    expect(
        () => mergeEvents([
              [
                {...events.first, 'extra': true}
              ]
            ]),
        throwsFormatException);
    expect(
        () => mergeEvents([
              events,
              [
                {...events.first, 'title': 'different'}
              ]
            ]),
        throwsFormatException);
    final song = events.firstWhere((e) => e['kind'] == 'putSong');
    expect(
        () => mergeEvents([
              [
                {
                  ...song,
                  'song': {...song['song'] as Map, 'youtubeId': 'invalid'}
                }
              ]
            ]),
        throwsFormatException);
    expect(
        () => mergeEvents([
              [
                {
                  ...song,
                  'song': Map<String, dynamic>.from(song['song'])
                    ..remove('thumbnailURL')
                }
              ]
            ]),
        throwsFormatException);
  });
  test(
      'durable journal survives restart; failed persistence never applies an edit',
      () async {
    final dir = await Directory.systemTemp.createTemp('evantube-store-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/state.json');
    final store = EvanLibraryStore(file);
    await store.mutate([
      {'kind': 'create', 'playlistId': 'p', 'title': 'Local'}
    ]);
    final loaded = EvanLibraryStore(file);
    await loaded.load();
    expect(loaded.playlists.single.title, 'Local');
    final broken = EvanLibraryStore(file,
        saveOverride: (_) async =>
            throw const FileSystemException('disk full'));
    await broken.load();
    await expectLater(
        broken.mutate([
          {'kind': 'rename', 'playlistId': 'p', 'title': 'Lost'}
        ]),
        throwsA(isA<FileSystemException>()));
    expect(broken.playlists.single.title, 'Local');
  });
  test(
      'edit arriving during upload is persisted after merge and included next sync',
      () async {
    final store = EvanLibraryStore(File('unused'), saveOverride: (_) async {});
    await store.activate('account-a');
    await store.mutate([
      {'kind': 'create', 'playlistId': 'local', 'title': 'Local'}
    ]);
    final enteredUpload = Completer<void>();
    final finishUpload = Completer<void>();
    final syncing =
        store.sync('account-a', () async => [events], (_, __) async {
      enteredUpload.complete();
      await finishUpload.future;
    });
    await enteredUpload.future;
    final editing = store.mutate([
      {'kind': 'rename', 'playlistId': 'local', 'title': 'Edited during upload'}
    ]);
    finishUpload.complete();
    await Future.wait([syncing, editing]);
    expect(store.playlists.last.title, 'Edited during upload');
    await store.sync('account-a', () async => [], (device, bytes) async {
      final own = decodeJournal(bytes);
      expect(own.every((e) => e['deviceId'] == device), isTrue);
      expect(own.last['title'], 'Edited during upload');
    });
  });
  test(
      'offline failures and account mismatch preserve local events and last sync',
      () async {
    final store = EvanLibraryStore(File('unused'), saveOverride: (_) async {});
    await store.activate('account-a');
    await store.mutate([
      {'kind': 'create', 'playlistId': 'p', 'title': 'Pending'}
    ]);
    final before = jsonEncode(store.events);
    await expectLater(
        store.sync(
            'account-a',
            () async => throw const SocketException('offline'),
            (_, __) async {}),
        throwsA(isA<SocketException>()));
    expect(jsonEncode(store.events), before);
    expect(store.lastSync, isNull);
    var networkCalled = false;
    await expectLater(
        store.sync('account-b', () async {
          networkCalled = true;
          return [];
        }, (_, __) async {}),
        throwsStateError);
    expect(networkCalled, isFalse);
    await store.disconnect();
    expect(store.playlists.single.title, 'Pending');
    final previousDevice = store.deviceId;
    await store.activate('account-b');
    expect(store.deviceId, isNot(previousDevice));
    expect(store.playlists.single.title, 'Pending');
    expect(store.events.every((e) => e['deviceId'] == store.deviceId), isTrue);
  });
}
