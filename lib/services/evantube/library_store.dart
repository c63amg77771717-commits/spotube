import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:uuid/uuid.dart';
import 'journal.dart';

const _localByteLimit = 25 * 1024 * 1024;

class EvanLibraryStore {
  final File file;
  final Future<void> Function(Map<String, dynamic>)? saveOverride;
  EvanLibraryStore(this.file, {this.saveOverride});
  String deviceId = const Uuid().v4();
  String? accountId;
  bool enabled = false;
  DateTime? lastSync;
  List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> get events => mergeEvents([_events]);
  List<EvanPlaylist> get playlists => replayJournal(_events);
  Future<void> _tail = Future.value();

  // ponytail: one queue holds sync and edits; split only if bounded sync latency becomes a problem.
  Future<T> serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> load() => serial(() async {
        if (!await file.exists()) return;
        if (await file.length() > _localByteLimit)
          throw const FormatException('Local journal is too large.');
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final parsed =
            mergeEvents([(data['events'] as List).map(validateEvent)]);
        final device = data['deviceId'] as String;
        validateEvent({
          'id': device,
          'deviceId': device,
          'clock': 1,
          'kind': 'orderPlaylists',
          'playlistId': '',
          'order': []
        });
        _events = parsed;
        deviceId = device;
        accountId = data['accountId'] as String?;
        enabled = data['enabled'] == true;
        lastSync = DateTime.tryParse(data['lastSync'] as String? ?? '');
      });

  Future<void> _save(List<Map<String, dynamic>> next,
      {String? device,
      String? account,
      bool? syncEnabled,
      DateTime? synced,
      bool clearSync = false}) async {
    final data = <String, dynamic>{
      'deviceId': device ?? deviceId,
      'accountId': account ?? accountId,
      'enabled': syncEnabled ?? enabled,
      'lastSync': clearSync ? null : (synced ?? lastSync)?.toIso8601String(),
      'events': next
    };
    final encoded = _encodeLocal(data);
    if (saveOverride != null) {
      await saveOverride!(data);
    } else {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(encoded, flush: true);
      await temporary.rename(file.path);
    }
    _events = next;
    deviceId = data['deviceId'];
    accountId = data['accountId'];
    enabled = data['enabled'];
    lastSync = DateTime.tryParse(data['lastSync'] ?? '');
  }

  List<int> _encodeLocal(Map<String, dynamic> data) {
    final bytes = utf8.encode(jsonEncode(data));
    if (bytes.length > _localByteLimit) {
      throw const FormatException('Local EvanTube journal exceeds 25 MiB.');
    }
    return bytes;
  }

  List<Map<String, dynamic>> _append(List<Map<String, dynamic>> base,
      List<Map<String, dynamic>> edits, String device) {
    var clock = base.fold<int>(0, (v, e) => max(v, e['clock'] as int));
    final added = edits.map((edit) {
      clock = max(DateTime.now().toUtc().millisecondsSinceEpoch, clock + 1);
      return validateEvent({
        ...edit,
        'id': const Uuid().v4(),
        'deviceId': device,
        'clock': clock
      });
    }).toList();
    final result = mergeEvents([base, added]);
    encodeJournal(result.where((e) => e['deviceId'] == device));
    return result;
  }

  Future<void> mutate(List<Map<String, dynamic>> edits) => serial(() async {
        await _save(_append(_events, edits, deviceId));
      });

  /// Only call after the user explicitly confirms merging into this account.
  Future<void> activate(String selectedAccount) => serial(() async {
        if (selectedAccount == accountId) {
          await _save(_events, syncEnabled: true);
          return;
        }
        final device = const Uuid().v4();
        final edits = <Map<String, dynamic>>[];
        for (final p in playlists) {
          edits.add({'kind': 'create', 'playlistId': p.id, 'title': p.title});
          for (final song in p.songs) {
            edits.add({'kind': 'putSong', 'playlistId': p.id, 'song': song});
          }
        }
        await _save(_append([], edits, device),
            device: device,
            account: selectedAccount,
            syncEnabled: true,
            clearSync: true);
      });

  Future<void> disconnect() => serial(() => _save(_events, syncEnabled: false));

  Future<void> sync(
          String selectedAccount,
          Future<List<List<Map<String, dynamic>>>> Function() download,
          Future<void> Function(String device, List<int> journal) upload) =>
      serial(() async {
        if (!enabled || accountId != selectedAccount)
          throw StateError('Activate this Google account before syncing.');
        final remote = await download();
        final merged = mergeEvents([_events, ...remote]);
        replayJournal(
            merged); // Validate the entire candidate before any upload/application.
        final synced = DateTime.now().toUtc();
        _encodeLocal({
          'deviceId': deviceId,
          'accountId': accountId,
          'enabled': enabled,
          'lastSync': synced.toIso8601String(),
          'events': merged
        });
        await upload(deviceId,
            encodeJournal(merged.where((e) => e['deviceId'] == deviceId)));
        await _save(merged, synced: synced);
      });
}
