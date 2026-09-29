import 'package:auto_route/auto_route.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/modules/connect/connect_device.dart';
import 'package:spotube/modules/home/sections/featured.dart';
import 'package:spotube/modules/home/sections/sections.dart';
import 'package:spotube/modules/home/sections/new_releases.dart';
import 'package:spotube/modules/home/sections/recent.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/utils/platform.dart';

@RoutePage()
class HomePage extends HookConsumerWidget {
  static const name = "home";
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final theme = Theme.of(context);
    final controller = useScrollController();
    final mediaQuery = MediaQuery.of(context);
    final layoutMode =
        ref.watch(userPreferencesProvider.select((s) => s.layoutMode));

    return SafeArea(
        bottom: false,
        child: Scaffold(
          headers: [
            if (kTitlebarVisible) const TitleBar(height: 30),
          ],
          child: CustomScrollView(
            controller: controller,
            slivers: [
              if (mediaQuery.smAndDown || layoutMode == LayoutMode.compact)
                SliverAppBar(
                  floating: true,
                  title: DefaultTextStyle(
                    style: TextStyle(
                      fontFamily: "Cookie",
                      fontSize: 30,
                      letterSpacing: 1.8,
                      color: theme.colorScheme.foreground,
                    ),
                    child: const Text("EvanTube"),
                  ),
                  backgroundColor: const Color(0xFF070A12),
                  foregroundColor: theme.colorScheme.foreground,
                  actions: [
                    const ConnectDeviceButton(),
                    const Gap(10),
                    IconButton.ghost(
                      icon: const Icon(SpotubeIcons.settings, size: 20),
                      onPressed: () {
                        context.navigateTo(const SettingsRoute());
                      },
                    ),
                    const Gap(10),
                  ],
                )
              else if (kIsMacOS)
                const SliverGap(10),
              const SliverGap(10),
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 14),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "晚安，音樂總在對的時候出現。",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF4F7FF),
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        "EvanTube · More Than Music",
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: .8,
                          color: Color(0xFF9BA8C7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: 3,
                itemBuilder: (context, index) {
                  return switch (index) {
                    // 0 => const HomeGenresSection(),
                    0 => const HomeRecentlyPlayedSection(),
                    1 => const HomeFeaturedSection(),
                    // 3 => const HomePageFriendsSection(),
                    _ => const HomeNewReleasesSection()
                  };
                },
              ),
              const SliverSafeArea(sliver: HomePageBrowseSection()),
            ],
          ),
        ));
  }
}
