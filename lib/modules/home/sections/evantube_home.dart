import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:flutter/material.dart' show RefreshIndicator;
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/evantube/neo_noir.dart';
import 'package:spotube/components/links/hyper_link.dart';
import 'package:spotube/components/horizontal_playbutton_card_view/horizontal_playbutton_card_view.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/pages/search/search.dart';
import 'package:spotube/provider/evantube/home_feed.dart';
import 'package:spotube/provider/history/recent.dart';
import 'package:spotube/provider/metadata_plugin/browse/sections.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/services/evantube/home_feed.dart';

const homeRegions = {
  'tw': '華語／台灣',
  'hk': '粵語／香港',
  'jp': '日語／日本',
  'kr': '韓語／韓國',
  'us': '英語／美國',
  'gb': '英語／英國',
  'sg': '華語／新加坡',
  'in': '印度／印度',
  'fr': '法語／法國',
  'de': '德語／德國',
  'es': '西語／西班牙',
  'br': '葡語／巴西'
};

class EvanTubeHome extends ConsumerWidget {
  const EvanTubeHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final region = ref.watch(homeRegionProvider);
    final history = ref.watch(recentlyPlayedItems);
    final authenticated = ref.watch(metadataPluginAuthenticatedProvider);
    final browse = ref.watch(metadataPluginBrowseSectionsProvider);
    final weeklySections = browse.asData?.value.items
            .where((s) =>
                s.items.isNotEmpty &&
                RegExp(r'weekly|本週|每週', caseSensitive: false).hasMatch(s.title))
            .toList() ??
        [];
    return RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(recentlyPlayedItems);
          ref.invalidate(metadataPluginBrowseSectionsProvider);
          ref.invalidate(onlineChartProvider);
          ref.invalidate(onlineWeeklyProvider);
          ref.invalidate(onlineReleasesProvider);
          await Future.wait([
            ref.read(onlineChartProvider(region).future),
            ref.read(onlineWeeklyProvider.future),
            ref.read(onlineReleasesProvider.future)
          ].map((f) =>
              f.then<void>((_) {}, onError: (Object _, StackTrace __) {})));
        },
        child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
            children: [
              Row(children: [
                Image.asset('assets/images/evantube-logo.png',
                    width: 42, height: 42),
                const Gap(10),
                const Text('Evan',
                    style: TextStyle(
                        fontSize: 29,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                const EvanTubeAccent(
                    child: Text('Tube',
                        style: TextStyle(
                            fontSize: 29, fontWeight: FontWeight.w700))),
                const Spacer(),
                EvanTubeAccent(
                    child: IconButton.ghost(
                        icon: const Icon(SpotubeIcons.search),
                        onPressed: () =>
                            context.navigateTo(const SearchRoute()))),
                IconButton.ghost(
                    icon: const Icon(SpotubeIcons.settings),
                    onPressed: () => context.navigateTo(const SettingsRoute()))
              ]),
              const Padding(
                  padding: EdgeInsets.only(top: 38, bottom: 14),
                  child: EvanTubeAccent(
                      child: Text('MORE THAN MUSIC',
                          style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 2.5,
                              fontWeight: FontWeight.w600)))),
              const Text('晚安，\n讓音樂陪你走過每個夜晚。',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700)),
              const Gap(6),
              const Text('為你而來',
                  style: TextStyle(color: evanSecondary, fontSize: 12)),
              const Gap(24),
              GestureDetector(
                onTap: () => context.navigateTo(const SearchRoute()),
                child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: evanCard,
                        borderRadius: BorderRadius.circular(14)),
                    child: const Row(children: [
                      EvanTubeAccent(
                          child: Icon(SpotubeIcons.search, size: 18)),
                      Gap(12),
                      Text('搜尋此刻的歌曲與新發行',
                          style: TextStyle(color: evanSecondary, fontSize: 13))
                    ])),
              ),
              const Gap(28),
              Row(children: [
                const EvanTubeAccent(
                    child: Icon(SpotubeIcons.history, size: 20)),
                const Gap(8),
                const Text('最近播放',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const Spacer(),
                Button.text(
                    onPressed: () => context.navigateTo(const LibraryRoute()),
                    child: const Text('媒體庫',
                        style: TextStyle(color: evanSecondary)))
              ]),
              const Gap(12),
              history.when(
                  loading: () => const FeedStatus('載入播放紀錄…'),
                  error: (e, s) => FeedStatus('播放紀錄暫時無法載入',
                      retry: () => ref.invalidate(recentlyPlayedItems)),
                  data: (rows) => !rows.any(
                          (row) => row.playlist != null || row.album != null)
                      ? const FeedStatus('播放音樂後，你的紀錄會出現在這裡。')
                      : HorizontalPlaybuttonCardView(
                          title: const SizedBox.shrink(),
                          items: [
                            for (final row in rows)
                              if (row.playlist != null)
                                row.playlist
                              else if (row.album != null)
                                row.album
                          ],
                          hasNextPage: false,
                          isLoadingNextPage: false,
                          onFetchMore: () {})),
              const _Heading('推薦音樂'),
              if (authenticated.isLoading)
                const FeedStatus('確認帳號連線…')
              else if (authenticated.asData?.value != true)
                FeedStatus('連接音樂帳號，取得為你推薦的音樂。',
                    retry: () => context
                        .navigateTo(const SettingsMetadataProviderRoute()),
                    action: '連接帳號')
              else
                browse.when(
                    loading: () => const FeedStatus('載入推薦音樂…'),
                    error: (e, s) => FeedStatus('推薦音樂暫時無法載入',
                        retry: () => ref
                            .invalidate(metadataPluginBrowseSectionsProvider)),
                    data: (data) => !data.items.any((s) =>
                            s.items.isNotEmpty && !weeklySections.contains(s))
                        ? const FeedStatus('目前沒有個人推薦。')
                        : Column(children: [
                            for (final section in data.items
                                .where((s) =>
                                    s.items.isNotEmpty &&
                                    !weeklySections.contains(s))
                                .take(2))
                              HorizontalPlaybuttonCardView(
                                  title: Text(section.title),
                                  items: section.items,
                                  hasNextPage: false,
                                  isLoadingNextPage: false,
                                  onFetchMore: () {})
                          ])),
              const _Heading('最近熱門'),
              _PublicFeed(
                  feed: ref.watch(onlineChartProvider('tw')),
                  retry: () => ref.invalidate(onlineChartProvider('tw'))),
              const _Heading('各語系音樂排行'),
              SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final entry in homeRegions.entries)
                      Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: EvanTubeAccentBorder(
                              child: Button.ghost(
                                  onPressed: () => ref
                                      .read(homeRegionProvider.notifier)
                                      .state = entry.key,
                                  child: Text(
                                      '${entry.value}${region == entry.key ? ' ✓' : ''}'))))
                  ])),
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('依地區排行，可能包含其他語言歌曲。',
                      style: TextStyle(color: evanSecondary, fontSize: 11))),
              _PublicFeed(
                  feed: ref.watch(onlineChartProvider(region)),
                  retry: () => ref.invalidate(onlineChartProvider(region))),
              const _Heading('本週精選'),
              if (authenticated.asData?.value == true &&
                  weeklySections.isNotEmpty)
                for (final section in weeklySections)
                  HorizontalPlaybuttonCardView(
                      title: Text(section.title),
                      items: section.items,
                      hasNextPage: false,
                      isLoadingNextPage: false,
                      onFetchMore: () {})
              else
                _PublicFeed(
                    feed: ref.watch(onlineWeeklyProvider),
                    retry: () => ref.invalidate(onlineWeeklyProvider)),
              const _Heading('最新發行'),
              _PublicFeed(
                  feed: ref.watch(onlineReleasesProvider),
                  retry: () => ref.invalidate(onlineReleasesProvider)),
            ]));
  }
}

class _Heading extends StatelessWidget {
  final String title;
  const _Heading(this.title);
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Text(title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)));
}

class FeedStatus extends StatelessWidget {
  final String text, action;
  final VoidCallback? retry;
  const FeedStatus(this.text, {super.key, this.retry, this.action = '重試'});
  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: evanCard, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: const TextStyle(color: evanSecondary)),
        if (retry != null)
          Padding(
              padding: const EdgeInsets.only(top: 10),
              child: EvanTubeAccentBorder(
                  child: Button.ghost(onPressed: retry, child: Text(action))))
      ]));
}

class _PublicFeed extends ConsumerWidget {
  final AsyncValue<OnlineMusicFeed> feed;
  final VoidCallback retry;
  const _PublicFeed({required this.feed, required this.retry});
  @override
  Widget build(BuildContext context, WidgetRef ref) => feed.when(
      loading: () => const FeedStatus('載入線上音樂…'),
      error: (e, s) => FeedStatus('來源暫時無法連線，請稍後重試。', retry: retry),
      data: (data) =>
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Hyperlink(
                '${data.sourceName}${data.periodStart == null ? '' : ' · 週期 ${data.periodStart!.toIso8601String().substring(0, 10)}'}${data.updatedAt == null ? '' : ' · 更新 ${data.updatedAt!.toIso8601String().substring(0, 10)}'}',
                data.sourceUrl,
                style: const TextStyle(color: evanSecondary, fontSize: 11)),
            const Gap(10),
            if (data.items.isEmpty)
              const FeedStatus('來源目前沒有可顯示的音樂。')
            else
              SizedBox(
                  height: 220,
                  child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: data.items.length.clamp(0, 20),
                      separatorBuilder: (c, i) => const Gap(12),
                      itemBuilder: (context, index) {
                        final item = data.items[index];
                        return GestureDetector(
                            onTap: () {
                              ref.read(searchTermStateProvider.notifier).state =
                                  '${item.title} ${item.artist ?? ''}'.trim();
                              context.navigateTo(const SearchRoute());
                            },
                            child: Container(
                                width: 145,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                    color: evanCard,
                                    borderRadius: BorderRadius.circular(14)),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          child: item.artworkUrl == null
                                              ? Container(
                                                  height: 112,
                                                  width: 125,
                                                  color: evanBackground,
                                                  child: const EvanTubeAccent(
                                                      child: Icon(
                                                          SpotubeIcons.music,
                                                          size: 38)))
                                              : Image.network(item.artworkUrl!,
                                                  height: 112,
                                                  width: 125,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (c, e, s) =>
                                                      const SizedBox(
                                                          height: 112,
                                                          child: Center(
                                                              child: Icon(
                                                                  SpotubeIcons
                                                                      .music))))),
                                      const Gap(8),
                                      Text(item.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600)),
                                      Text(item.artist ?? '藝術家資料未提供',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: evanSecondary)),
                                      if (item.releaseDate != null)
                                        Text(
                                            item.releaseDate!
                                                .toIso8601String()
                                                .substring(0, 10),
                                            style: const TextStyle(
                                                fontSize: 10,
                                                color: evanSecondary))
                                    ])));
                      })),
          ]));
}
