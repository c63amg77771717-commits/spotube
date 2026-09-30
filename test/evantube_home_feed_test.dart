import 'package:dio/dio.dart';
import 'package:test/test.dart';
import '../lib/services/evantube/home_feed.dart';

void main() {
  test('Apple preserves real fields and update time', () {
    final feed = parseAppleChart({
      'feed': {
        'updated': '2026-09-30T00:00:00Z',
        'results': [
          {
            'id': '1',
            'name': '歌曲',
            'artistName': '歌手',
            'url': 'https://music.apple.com/a',
            'artworkUrl100': 'https://example.org/a.jpg'
          }
        ]
      }
    });
    expect(feed.items.single.title, '歌曲');
    expect(feed.updatedAt, DateTime.utc(2026, 9, 30));
  });
  test('weekly deduplicates recording IDs and preserves period', () {
    final feed = parseWeeklyChart({
      'payload': {
        'from_ts': 1789948800,
        'last_updated': 1790743833,
        'recordings': [
          for (var i = 0; i < 2; i++)
            {
              'recording_mbid': 'a',
              'track_name': 'Song',
              'artist_name': 'Artist'
            }
        ]
      }
    });
    expect(feed.items.map((e) => e.id), ['a']);
    expect(feed.periodStart, isNotNull);
  });
  test('releases exclude future dates and sort newest first', () {
    final feed = parseFreshReleases({
      'payload': {
        'releases': [
          for (final date in ['2026-09-28', '2026-09-30', '2026-10-01'])
            {
              'release_mbid': date,
              'release_name': date,
              'artist_credit_name': 'Artist',
              'release_date': date
            }
        ]
      }
    }, now: DateTime.utc(2026, 9, 30));
    expect(feed.items.map((e) => e.title), ['2026-09-30', '2026-09-28']);
  });
  test('malformed and empty data never invent rows', () {
    expect(parseAppleChart(null).items, isEmpty);
    expect(
        parseWeeklyChart({
          'payload': {
            'recordings': [{}, null]
          }
        }).items,
        isEmpty);
    expect(parseFreshReleases({}).items, isEmpty);
  });
  test('network errors propagate with finite timeout', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      expect(options.receiveTimeout, isNotNull);
      handler.reject(DioException(
          requestOptions: options, type: DioExceptionType.connectionTimeout));
    }));
    await expectLater(
        OnlineMusicClient(dio).weekly(), throwsA(isA<DioException>()));
  });
}
