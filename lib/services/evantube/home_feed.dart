import 'package:dio/dio.dart';

class OnlineMusicItem {
  final String id, title;
  final String? artist, sourceUrl, artworkUrl;
  final String kind;
  final DateTime? releaseDate;
  const OnlineMusicItem(
      {required this.id,
      required this.title,
      this.artist,
      this.sourceUrl,
      this.artworkUrl,
      required this.kind,
      this.releaseDate});
}

class OnlineMusicFeed {
  final String sourceName, sourceUrl;
  final DateTime? updatedAt, periodStart;
  final List<OnlineMusicItem> items;
  const OnlineMusicFeed(
      {required this.sourceName,
      required this.sourceUrl,
      this.updatedAt,
      this.periodStart,
      required this.items});
}

Map _map(Object? value) => value is Map ? value : const {};
List _list(Object? value) => value is List ? value : const [];
String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
DateTime? _date(Object? value) => value is num
    ? DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000, isUtc: true)
    : value is String
        ? DateTime.tryParse(value)
        : null;

OnlineMusicFeed parseAppleChart(Object? raw, {String region = 'tw'}) {
  final feed = _map(_map(raw)['feed']);
  final items = <OnlineMusicItem>[];
  for (final value in _list(feed['results'])) {
    final row = _map(value);
    final id = _text(row['id']), title = _text(row['name']);
    if (id == null || title == null) continue;
    items.add(OnlineMusicItem(
        id: id,
        title: title,
        artist: _text(row['artistName']),
        sourceUrl: _text(row['url']),
        artworkUrl: _text(row['artworkUrl100']),
        kind: 'song'));
  }
  return OnlineMusicFeed(
      sourceName: 'Apple Music · ${region.toUpperCase()}',
      sourceUrl:
          'https://rss.marketingtools.apple.com/api/v2/$region/music/most-played/20/songs.json',
      updatedAt: _date(feed['updated']),
      items: items);
}

OnlineMusicFeed parseWeeklyChart(Object? raw) {
  final payload = _map(_map(raw)['payload']);
  final ids = <String>{}, items = <OnlineMusicItem>[];
  for (final value in _list(payload['recordings'])) {
    final row = _map(value);
    final id = _text(row['recording_mbid']), title = _text(row['track_name']);
    if (id == null || title == null || !ids.add(id)) continue;
    items.add(OnlineMusicItem(
        id: id,
        title: title,
        artist: _text(row['artist_name']),
        sourceUrl: 'https://musicbrainz.org/recording/$id',
        artworkUrl: row['caa_id'] is num &&
                _text(row['caa_release_mbid']) != null
            ? 'https://archive.org/download/mbid-${row['caa_release_mbid']}/${row['caa_id']}-250.jpg'
            : null,
        kind: 'song'));
  }
  return OnlineMusicFeed(
      sourceName: 'ListenBrainz 社群週榜',
      sourceUrl:
          'https://api.listenbrainz.org/1/stats/sitewide/recordings?range=week&count=20',
      updatedAt: _date(payload['last_updated']),
      periodStart: _date(payload['from_ts']),
      items: items);
}

OnlineMusicFeed parseFreshReleases(Object? raw, {DateTime? now}) {
  final payload = _map(_map(raw)['payload']);
  final today = now ?? DateTime.now();
  final cutoff = DateTime.utc(today.year, today.month, today.day);
  final items = <OnlineMusicItem>[], ids = <String>{};
  for (final value in _list(payload['releases'])) {
    final row = _map(value);
    final id = _text(row['release_mbid']), title = _text(row['release_name']);
    final date = _date(row['release_date']);
    if (id == null ||
        title == null ||
        date == null ||
        date.isAfter(cutoff) ||
        !ids.add(id)) {
      continue;
    }
    final coverId = row['caa_id'];
    items.add(OnlineMusicItem(
        id: id,
        title: title,
        artist: _text(row['artist_credit_name']),
        sourceUrl: 'https://musicbrainz.org/release/$id',
        artworkUrl: coverId is num
            ? 'https://archive.org/download/mbid-${_text(row['caa_release_mbid']) ?? id}/$coverId-250.jpg'
            : null,
        kind: 'release',
        releaseDate: date));
  }
  items.sort((a, b) => b.releaseDate!.compareTo(a.releaseDate!));
  return OnlineMusicFeed(
      sourceName: 'ListenBrainz · MusicBrainz 最新發行',
      sourceUrl:
          'https://api.listenbrainz.org/1/explore/fresh-releases?days=7&future=false',
      updatedAt: _date(payload['last_updated']),
      items: items);
}

class OnlineMusicClient {
  final Dio dio;
  OnlineMusicClient(this.dio);
  Future<Object?> _get(String url) async {
    final cancel = CancelToken();
    try {
      return (await dio
              .get<Object?>(url,
                  cancelToken: cancel,
                  options: Options(
                      receiveTimeout: const Duration(seconds: 15),
                      sendTimeout: const Duration(seconds: 15)))
              .timeout(const Duration(seconds: 25), onTimeout: () {
        cancel.cancel('Online music request timed out');
        throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.receiveTimeout);
      }))
          .data;
    } finally {
      if (!cancel.isCancelled) cancel.cancel('Request finished');
    }
  }

  Future<OnlineMusicFeed> chart(String region) async {
    if (!const [
      'tw',
      'hk',
      'jp',
      'kr',
      'us',
      'gb',
      'cn',
      'sg',
      'in',
      'fr',
      'de',
      'es',
      'br'
    ].contains(region)) {
      throw ArgumentError.value(region, 'region');
    }
    return parseAppleChart(
        await _get(
            'https://rss.marketingtools.apple.com/api/v2/$region/music/most-played/20/songs.json'),
        region: region);
  }

  Future<OnlineMusicFeed> weekly() async => parseWeeklyChart(await _get(
      'https://api.listenbrainz.org/1/stats/sitewide/recordings?range=week&count=20'));
  Future<OnlineMusicFeed> releases({DateTime? now}) async => parseFreshReleases(
      await _get(
          'https://api.listenbrainz.org/1/explore/fresh-releases?days=7&future=false'),
      now: now);
}
