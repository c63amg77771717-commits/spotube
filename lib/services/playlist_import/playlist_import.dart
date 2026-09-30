import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class PlaylistImportTrack {
  final String title;
  final String? youtubeId;
  final String? trackId;
  final String artist;
  final int durationSeconds;
  final int order;

  const PlaylistImportTrack({
    required this.title,
    this.youtubeId,
    this.trackId,
    this.artist = '',
    this.durationSeconds = 0,
    this.order = 0,
  });

  String get sourceUrl => youtubeId == null
      ? ''
      : 'https://www.youtube.com/watch?v=$youtubeId';
}

class PlaylistImportPlaylist {
  final String sourceId;
  final String name;
  final List<PlaylistImportTrack> tracks;
  final int duplicateCount;

  const PlaylistImportPlaylist({
    required this.sourceId,
    required this.name,
    required this.tracks,
    this.duplicateCount = 0,
  });
}

class PlaylistImportDocument {
  final List<PlaylistImportPlaylist> playlists;
  final List<String> warnings;
  final int rowCount;

  const PlaylistImportDocument({
    required this.playlists,
    this.warnings = const [],
    required this.rowCount,
  });
}

PlaylistImportDocument parsePlaylistImport(Uint8List bytes, String filename) {
  if (bytes.length > 32 * 1024 * 1024) {
    throw const FormatException('歌單檔案不可超過 32 MB。');
  }
  final files = <String, Uint8List>{};
  if (_extension(filename) == 'zip') {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.length > 512 ||
          archive.fold<int>(0, (sum, file) => sum + file.size) >
              64 * 1024 * 1024) {
        throw const FormatException('ZIP 內容過大，請分批匯入。');
      }
      for (final file in archive) {
        final name = file.name.replaceAll('\\', '/');
        if (name.startsWith('/') ||
            name.split('/').contains('..') ||
            RegExp(r'^[a-zA-Z]:').hasMatch(name)) {
          throw const FormatException('ZIP 包含不安全的檔案路徑。');
        }
        if (!file.isFile || name.startsWith('__MACOSX/')) continue;
        if (_supported.contains(_extension(name)) &&
            !['readme', 'playlist_manifest'].contains(_stem(name).toLowerCase())) {
          files[name] = Uint8List.fromList(file.content);
        }
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('無法開啟 ZIP，請確認檔案完整且未加密。');
    }
  } else if (_supported.contains(_extension(filename))) {
    files[filename] = bytes;
  } else {
    throw const FormatException('請選擇 ZIP、JSON、CSV、TXT、M3U 或 M3U8。');
  }
  if (files.isEmpty) {
    throw const FormatException('找不到可匯入的歌單；音樂檔不屬於歌單格式。');
  }

  // MB3 exports the same songs as combined and per-playlist files in three formats.
  final combinedJson = files.keys.where((name) =>
      _basename(name).toLowerCase() == 'mb3_all_playlists.json');
  final combinedCsv = files.keys.where((name) =>
      _basename(name).toLowerCase() == 'mb3_all_playlists.csv');
  final selected = <String>[];
  if (combinedJson.isNotEmpty) {
    selected.add(combinedJson.first);
  } else if (combinedCsv.isNotEmpty) {
    selected.add(combinedCsv.first);
  } else {
    final preferred = <String, String>{};
    for (final name in files.keys) {
      final key = name.substring(0, name.lastIndexOf('.')).toLowerCase();
      final old = preferred[key];
      if (old == null ||
          _supported.indexOf(_extension(name)) <
              _supported.indexOf(_extension(old))) {
        preferred[key] = name;
      }
    }
    selected.addAll(preferred.values);
  }

  final builder = _ImportBuilder();
  for (final name in selected) {
    final text = utf8.decode(files[name]!).replaceFirst(RegExp(r'^\uFEFF'), '');
    final fallback = _stem(name);
    switch (_extension(name)) {
      case 'json':
        builder.readJson(jsonDecode(text), fallback);
      case 'csv':
        final rows = _readCsv(text);
        if (rows.isEmpty) continue;
        final headers = rows.first.map((h) => h.trim().toLowerCase()).toList();
        for (final row in rows.skip(1)) {
          if (row.every((cell) => cell.trim().isEmpty)) continue;
          builder.addRow({
            for (var i = 0; i < headers.length; i++)
              headers[i]: i < row.length ? row[i] : '',
          }, fallback);
        }
      default:
        String? title;
        var duration = 0;
        for (final raw in const LineSplitter().convert(text)) {
          final line = raw.trim();
          if (line.isEmpty) continue;
          if (line.startsWith('#EXTINF:')) {
            final comma = line.indexOf(',');
            if (comma != -1) {
              duration = int.tryParse(line.substring(8, comma)) ?? 0;
              title = line.substring(comma + 1).trim();
            }
          } else if (!line.startsWith('#')) {
            builder.addRow({
              'title': title ?? (line.startsWith('http') ? '' : line),
              'youtube_url': line,
              'duration_seconds': duration,
            }, fallback);
            title = null;
            duration = 0;
          }
        }
    }
  }
  return builder.build();
}

const _supported = ['json', 'csv', 'm3u8', 'm3u', 'txt'];
String _basename(String name) => name.replaceAll('\\', '/').split('/').last;
String _extension(String name) => _basename(name).split('.').last.toLowerCase();
String _stem(String name) => _basename(name).replaceFirst(RegExp(r'\.[^.]+$'), '');
String _string(dynamic value) => value?.toString().trim() ?? '';
int _integer(dynamic value) => int.tryParse(_string(value)) ?? 0;

String? youtubeIdFromImport(String value) {
  if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(value)) return value;
  final uri = Uri.tryParse(value);
  if (uri == null || !['http', 'https'].contains(uri.scheme)) return null;
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments;
  String? id;
  if (host == 'youtu.be') {
    id = segments.firstOrNull;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    id = uri.queryParameters['v'];
    if (id == null && segments.length >= 2 &&
        ['shorts', 'embed', 'live'].contains(segments.first)) {
      id = segments[1];
    }
  }
  return id != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id) ? id : null;
}

class _ImportBuilder {
  final names = <String, String>{};
  final tracks = <String, List<PlaylistImportTrack>>{};
  final warnings = <String>[];
  int rowCount = 0;

  String key(Map row, String fallback) {
    final id = _string(row['playlist_id']);
    return id.isNotEmpty
        ? '${_string(row['category'])}:$id'
        : 'name:${_string(row['playlist_name']).isEmpty ? fallback : row['playlist_name']}';
  }

  void addPlaylist(Map row, String fallback) {
    final id = key(row, fallback);
    final name = _string(row['playlist_name'] ?? row['name']);
    if (!names.containsKey(id) || name.isNotEmpty) {
      names[id] = name.isEmpty ? fallback : name;
    }
    tracks.putIfAbsent(id, () => []);
  }

  void readJson(dynamic data, String fallback) {
    if (data is List) {
      for (final row in data) {
        if (row is Map && (row['songs'] is List || row['tracks'] is List)) {
          readJson(row, fallback);
        } else {
          addRow(row, fallback);
        }
      }
      return;
    }
    if (data is! Map) throw const FormatException('JSON 必須包含歌單或歌曲清單。');
    final playlists = data['playlists'];
    if (playlists is List) {
      for (final playlist in playlists) {
        if (playlist is! Map) continue;
        addPlaylist(playlist, fallback);
        if (playlist['songs'] is List || playlist['tracks'] is List) {
          readJson(playlist, fallback);
        }
      }
    } else {
      addPlaylist(data, fallback);
    }
    final rows = data['songs'] ?? data['tracks'];
    if (rows is List) {
      for (final row in rows) {
        addRow(row is Map ? {
          'category': data['category'],
          'playlist_id': data['playlist_id'],
          'playlist_name': data['playlist_name'] ?? data['name'],
          ...row,
        } : row, fallback);
      }
    } else if (playlists is! List) {
      throw const FormatException('JSON 找不到 songs 或 tracks。');
    }
  }

  void addRow(dynamic raw, String fallback) {
    rowCount++;
    if (rowCount > 20000) throw const FormatException('單次最多匯入 20,000 筆歌曲。');
    if (raw is! Map) {
      warnings.add('第 $rowCount 筆不是有效歌曲資料。');
      return;
    }
    final title = _string(raw['title'] ?? raw['name']);
    final source = _string(raw['youtube_id'] ?? raw['videoId'] ??
        raw['video_id'] ?? raw['youtube_url'] ?? raw['url']);
    final youtubeId = youtubeIdFromImport(source);
    final trackId = _string(raw['track_id'] ?? raw['metadata_id']);
    final isLink = source.startsWith('http');
    if ((source.isNotEmpty && youtubeId == null &&
            (isLink || raw.containsKey('youtube_id'))) ||
        (title.isEmpty && youtubeId == null && trackId.isEmpty)) {
      warnings.add('第 $rowCount 筆缺少可用的歌曲名稱或 YouTube ID：$title');
      return;
    }
    addPlaylist(raw, fallback);
    final duration = _integer(raw['duration_seconds']);
    tracks[key(raw, fallback)]!.add(PlaylistImportTrack(
      title: title.isEmpty ? youtubeId ?? trackId : title,
      youtubeId: youtubeId,
      trackId: trackId.isEmpty ? null : trackId,
      artist: _string(raw['artist'] ?? raw['artist_name']),
      durationSeconds: duration < 0 ? 0 : duration,
      order: _integer(raw['order']) == 0 ? rowCount : _integer(raw['order']),
    ));
  }

  PlaylistImportDocument build() {
    final playlists = <PlaylistImportPlaylist>[];
    for (final entry in names.entries) {
      final sorted = tracks[entry.key]!.asMap().entries.toList()
        ..sort((a, b) {
          final order = a.value.order.compareTo(b.value.order);
          return order == 0 ? a.key.compareTo(b.key) : order;
        });
      final seen = <String>{};
      final unique = <PlaylistImportTrack>[];
      for (final row in sorted) {
        final track = row.value;
        final identity = track.youtubeId ?? track.trackId ??
            '${track.title.toLowerCase()}|${track.artist.toLowerCase()}';
        if (seen.add(identity)) unique.add(track);
      }
      playlists.add(PlaylistImportPlaylist(
        sourceId: entry.key,
        name: entry.value,
        tracks: unique,
        duplicateCount: sorted.length - unique.length,
      ));
    }
    if (playlists.every((p) => p.tracks.isEmpty)) {
      throw const FormatException('找不到可匯入的歌曲。');
    }
    return PlaylistImportDocument(playlists: playlists, warnings: warnings,
        rowCount: rowCount);
  }
}

List<List<String>> _readCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  var cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '"') {
      if (quoted && i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (char == ',' && !quoted) {
      row.add(cell.toString());
      cell = StringBuffer();
    } else if ((char == '\n' || char == '\r') && !quoted) {
      row.add(cell.toString());
      rows.add(row);
      row = [];
      cell = StringBuffer();
      if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
    } else {
      cell.write(char);
    }
  }
  if (quoted) throw const FormatException('CSV 的引號未成對，請重新匯出。');
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}
