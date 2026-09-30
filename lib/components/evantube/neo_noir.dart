import 'package:shadcn_flutter/shadcn_flutter.dart';

const evanBackground = Color(0xff080d15);
const evanCard = Color(0xff111b28);
const evanSecondary = Color(0xffa4afc1);
const evanGradient = LinearGradient(colors: [
  Color(0xffc174ff),
  Color(0xffac70ff),
  Color(0xff729eff),
  Color(0xff84dfff)
], stops: [
  0,
  .5,
  .82,
  1
], begin: Alignment.centerLeft, end: Alignment.centerRight);

class EvanTubeAccent extends StatelessWidget {
  final Widget child;
  const EvanTubeAccent({super.key, required this.child});
  @override
  Widget build(BuildContext context) => ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => evanGradient.createShader(bounds),
      child: child);
}

class EvanTubeAccentBorder extends StatelessWidget {
  final Widget child;
  final BorderRadius? borderRadius;
  const EvanTubeAccentBorder(
      {super.key, required this.child, this.borderRadius});
  @override
  Widget build(BuildContext context) => Container(
      decoration: BoxDecoration(
          gradient: evanGradient,
          borderRadius: borderRadius ?? BorderRadius.circular(12)),
      padding: const EdgeInsets.all(1),
      child: Container(
          decoration: BoxDecoration(
              color: evanCard,
              borderRadius: borderRadius ?? BorderRadius.circular(12)),
          child: child));
}
