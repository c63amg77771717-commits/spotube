import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import '../lib/services/playlist_import/playlist_import.dart';

Uint8List zipFiles(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  final combined = jsonEncode({
    'playlists': [
      {'category': 'own', 'playlist_id': '1', 'playlist_name': '中文 🎵'},
      {'category': 'saved', 'playlist_id': '2', 'playlist_name': '日本語'},
    ],
    'songs': [
      {'category': 'own', 'playlist_id': '1', 'order': 2,
       'youtube_id': 'IdneKLhsWOQ', 'title': '第二首', 'duration_seconds': 235},
      {'category': 'own', 'playlist_id': '1', 'order': 1,
       'youtube_id': 'b9WqhqJgjTE', 'title': '第一首'},
      {'category': 'own', 'playlist_id': '1', 'order': 3,
       'youtube_id': 'b9WqhqJgjTE', 'title': '重複'},
      {'category': 'saved', 'playlist_id': '2', 'order': 1,
       'youtube_id': 'b9WqhqJgjTE', 'title': '跨歌單保留'},
    ],
  });

  test('ZIP prefers combined JSON over all duplicate exports', () {
    final doc = parsePlaylistImport(zipFiles({
      'nested/MB3_All_Playlists.json': combined,
      'own_1.json': jsonEncode({'songs': [{'title': '不要重複讀取'}]}),
      'MB3_All_Playlists.csv': 'title\n不要重複讀取',
      'own_1.m3u8': '#EXTM3U\nhttps://youtu.be/b9WqhqJgjTE',
      'README.txt': 'MB3 complete playlist export',
      'playlist_manifest.csv': 'playlist_id,song_count\n1,3',
    }), 'MB3.zip');
    expect(doc.rowCount, 4);
    expect(doc.playlists.map((p) => p.name), ['中文 🎵', '日本語']);
    expect(doc.playlists[0].tracks.map((t) => t.title), ['第一首', '第二首']);
    expect(doc.playlists[0].duplicateCount, 1);
    expect(doc.playlists[1].tracks.single.youtubeId, 'b9WqhqJgjTE');
    expect(doc.playlists[0].tracks[1].durationSeconds, 235);
  });

  test('CSV preserves BOM, quoted commas, newlines and playlist boundaries', () {
    final csv = '\uFEFFplaylist_id,playlist_name,order,youtube_url,title\r\n'
        '1,中文,1,https://youtu.be/b9WqhqJgjTE,"歌名, \"\"版本\"\"\n續行"\r\n'
        '2,한국어,1,https://www.youtube.com/watch?v=IdneKLhsWOQ,第二首\r\n';
    final doc = parsePlaylistImport(Uint8List.fromList(utf8.encode(csv)), 'songs.csv');
    expect(doc.playlists.length, 2);
    expect(doc.playlists[0].tracks.single.title, '歌名, "版本"\n續行');
    expect(doc.playlists[1].name, '한국어');
  });

  test('M3U8 preserves EXTINF names and direct YouTube IDs', () {
    final doc = parsePlaylistImport(Uint8List.fromList(utf8.encode(
      '#EXTM3U\n#EXTINF:227,張靚穎 - 春花厭\nhttps://youtu.be/b9WqhqJgjTE\n'
      '#EXTINF:235,Taylor Swift - Wildest Dreams\nhttps://www.youtube.com/watch?v=IdneKLhsWOQ\n',
    )), '我的歌單.m3u8');
    expect(doc.playlists.single.name, '我的歌單');
    expect(doc.playlists.single.tracks.first.title, '張靚穎 - 春花厭');
    expect(doc.playlists.single.tracks.first.durationSeconds, 227);
  });

  test('ZIP rejects traversal names before reading content', () {
    expect(() => parsePlaylistImport(zipFiles({'../songs.json': combined}), 'bad.zip'),
      throwsFormatException);
  });

  test('unsupported ZIP and malformed JSON return actionable errors', () {
    expect(() => parsePlaylistImport(zipFiles({'README.txt': 'hello'}), 'empty.zip'),
      throwsFormatException);
    expect(() => parsePlaylistImport(Uint8List.fromList(utf8.encode('{oops')), 'bad.json'),
      throwsFormatException);
  });

  test('TXT ignores blank lines and separates invalid IDs from valid songs', () {
    final doc = parsePlaylistImport(Uint8List.fromList(utf8.encode(
      '\nhttps://youtu.be/b9WqhqJgjTE\nbad singer - good title\n'
      'https://www.youtube.com/watch?v=invalid\n',
    )), 'songs.txt');
    expect(doc.playlists.single.tracks.length, 2);
    expect(doc.warnings.length, 1);
  });

  final fixture = Platform.environment['MB3_TEST_ZIP'];
  if (fixture != null) {
    test('user MB3 ZIP contains seven playlists and 1186 source records', () {
      final doc = parsePlaylistImport(File(fixture).readAsBytesSync(), 'MB3.zip');
      expect(doc.rowCount, 1186);
      expect(doc.playlists.map((p) => p.name), [
        'Player', 'Techno', '本月新歌精選 (201803)', '本月熱門排行 (201803)',
        'Best of the Month (Mar. 2018)', '2018年3月邦楽 TOP ランキング',
        '이달의인기가요(2018년3월)',
      ]);
      expect(doc.playlists.first.tracks.first.youtubeId, 'b9WqhqJgjTE');
      expect(doc.playlists.first.tracks.first.title, contains('張靚穎'));
      expect(doc.warnings, isEmpty);
    });
  }
}
