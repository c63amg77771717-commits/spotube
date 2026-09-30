import 'package:auto_route/auto_route.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/components/evantube/neo_noir.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/modules/home/sections/evantube_home.dart';

@RoutePage()
class HomePage extends StatelessWidget {
  static const name = 'home';
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) => SafeArea(
      bottom: false,
      child: Scaffold(
          backgroundColor: evanBackground,
          headers: [if (kTitlebarVisible) const TitleBar(height: 30)],
          child: const EvanTubeHome()));
}
