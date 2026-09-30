import 'dart:convert';

const journalByteLimit = 5 * 1024 * 1024;
const journalEventLimit = 20000;
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final youtubeIdPattern = RegExp(r'^[a-zA-Z0-9_-]{11}$');

class EvanPlaylist {
  final String id;
  String title;
  final List<Map<String, dynamic>> songs;
  EvanPlaylist(this.id, this.title, [List<Map<String, dynamic>>? songs])
      : songs = songs ?? [];
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'songs': songs};
}

Never _invalid() => throw const FormatException('Invalid EvanTube journal.');
bool _id(dynamic s, {bool empty = false}) =>
    s is String &&
    (empty || s.isNotEmpty) &&
    s.length <= 128 &&
    s.codeUnits.every((c) => c < 128);
bool _text(dynamic s, {bool nonempty = false}) =>
    s is String && s.runes.length <= 1000 && (!nonempty || s.isNotEmpty);

Map<String, dynamic> validateEvent(dynamic raw) {
  if (raw is! Map<String, dynamic>) _invalid();
  final e = raw;
  if (e['id'] is! String ||
      !_uuid.hasMatch(e['id']) ||
      e['deviceId'] is! String ||
      !_uuid.hasMatch(e['deviceId']) ||
      e['clock'] is! int ||
      e['clock'] <= 0 ||
      e['clock'] > 9007199254740991 ||
      !_id(e['playlistId'], empty: e['kind'] == 'orderPlaylists') ||
      (e['kind'] == 'orderPlaylists' && e['playlistId'] != '')) _invalid();
  final result = <String, dynamic>{
    for (final key in ['id', 'deviceId', 'clock', 'kind', 'playlistId'])
      key: e[key]
  };
  switch (e['kind']) {
    case 'create':
    case 'rename':
      if (!_text(e['title'], nonempty: true)) _invalid();
      result['title'] = e['title'];
    case 'delete':
      break;
    case 'putSong':
      final s = e['song'];
      if (s is! Map<String, dynamic> ||
          s.length != 5 ||
          !s.containsKey('thumbnailURL') ||
          s['youtubeId'] is! String ||
          !youtubeIdPattern.hasMatch(s['youtubeId']) ||
          !_text(s['title']) ||
          !_text(s['artist']) ||
          s['duration'] is! int ||
          s['duration'] < 0 ||
          s['duration'] > 9007199254740991 ||
          (s['thumbnailURL'] != null && s['thumbnailURL'] is! String))
        _invalid();
      result['song'] = {
        for (final k in [
          'youtubeId',
          'title',
          'artist',
          'duration',
          'thumbnailURL'
        ])
          k: s[k]
      };
    case 'removeSong':
      if (e['songId'] is! String || !youtubeIdPattern.hasMatch(e['songId']))
        _invalid();
      result['songId'] = e['songId'];
    case 'orderSongs':
    case 'orderPlaylists':
      if (e['order'] is! List ||
          (e['order'] as List).length > journalEventLimit ||
          !(e['order'] as List).every((v) =>
              _id(v) &&
              (e['kind'] != 'orderSongs' || youtubeIdPattern.hasMatch(v))))
        _invalid();
      result['order'] = List<String>.from(e['order']);
    default:
      _invalid();
  }
  if (e.length != result.length || !e.keys.every(result.containsKey))
    _invalid();
  return result;
}

List<Map<String, dynamic>> decodeJournal(List<int> bytes) {
  if (bytes.length > journalByteLimit) _invalid();
  final doc = jsonDecode(utf8.decode(bytes));
  if (doc is! Map ||
      doc.length != 2 ||
      doc['schemaVersion'] is! int ||
      doc['schemaVersion'] != 1 ||
      doc['events'] is! List) _invalid();
  return mergeEvents([(doc['events'] as List).map(validateEvent)]);
}

List<int> encodeJournal(Iterable<Map<String, dynamic>> events) {
  final bytes =
      utf8.encode(jsonEncode({'schemaVersion': 1, 'events': events.toList()}));
  if (bytes.length > journalByteLimit)
    throw const FormatException('EvanTube journal exceeds 5 MiB.');
  return bytes;
}

List<Map<String, dynamic>> mergeEvents(
    Iterable<Iterable<Map<String, dynamic>>> journals) {
  final byId = <String, Map<String, dynamic>>{};
  for (final journal in journals) {
    for (final raw in journal) {
      final e = validateEvent(raw);
      final previous = byId[e['id']];
      if (previous != null && jsonEncode(previous) != jsonEncode(e)) _invalid();
      byId[e['id']] = e;
      if (byId.length > journalEventLimit)
        throw const FormatException('EvanTube exceeds 20,000 events.');
    }
  }
  return byId.values.toList()
    ..sort((a, b) {
      final clock = (a['clock'] as int).compareTo(b['clock'] as int);
      return clock != 0
          ? clock
          : (a['id'] as String).compareTo(b['id'] as String);
    });
}

void _reorder<T>(List<T> items, List<dynamic> order, String Function(T) id) {
  final byId = {for (final item in items) id(item): item};
  final result = <T>[];
  for (final key in order) {
    final item = byId.remove(key);
    if (item != null) result.add(item);
  }
  result.addAll(items.where((item) => byId.containsKey(id(item))));
  items
    ..clear()
    ..addAll(result);
}

List<EvanPlaylist> replayJournal(Iterable<Map<String, dynamic>> events) {
  final sorted = mergeEvents([events]);
  final deleted = sorted
      .where((e) => e['kind'] == 'delete')
      .map((e) => e['playlistId'])
      .toSet();
  final playlists = <EvanPlaylist>[];
  final byId = <String, EvanPlaylist>{};
  for (final e in sorted) {
    final id = e['playlistId'] as String;
    if (e['kind'] == 'orderPlaylists') {
      _reorder(playlists, e['order'], (p) => p.id);
      continue;
    }
    if (deleted.contains(id)) continue;
    if (e['kind'] == 'create' && !byId.containsKey(id)) {
      final p = EvanPlaylist(id, e['title']);
      byId[id] = p;
      playlists.add(p);
    }
    final p = byId[id];
    if (p == null) continue;
    switch (e['kind']) {
      case 'rename':
        p.title = e['title'];
      case 'putSong':
        final song = Map<String, dynamic>.from(e['song']);
        final index =
            p.songs.indexWhere((s) => s['youtubeId'] == song['youtubeId']);
        if (index < 0) {
          p.songs.add(song);
        } else {
          p.songs[index] = song;
        }
      case 'removeSong':
        p.songs.removeWhere((s) => s['youtubeId'] == e['songId']);
      case 'orderSongs':
        _reorder(p.songs, e['order'], (s) => s['youtubeId'] as String);
    }
  }
  return playlists;
}
