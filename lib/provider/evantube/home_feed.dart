import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/services/evantube/home_feed.dart';

final onlineMusicClientProvider = Provider((ref) {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
  ref.onDispose(() => dio.close(force: true));
  return OnlineMusicClient(dio);
});
final homeRegionProvider = StateProvider<String>((ref) => 'tw');
final onlineChartProvider = FutureProvider.family<OnlineMusicFeed, String>(
    (ref, region) => ref.watch(onlineMusicClientProvider).chart(region));
final onlineWeeklyProvider = FutureProvider<OnlineMusicFeed>(
    (ref) => ref.watch(onlineMusicClientProvider).weekly());
final onlineReleasesProvider = FutureProvider<OnlineMusicFeed>(
    (ref) => ref.watch(onlineMusicClientProvider).releases());
