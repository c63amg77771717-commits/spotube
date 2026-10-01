"""Verify the iOS target has no advertising SDK or attribution configuration."""

from pathlib import Path
import plistlib
import re


root = Path(__file__).resolve().parents[1]
ad_pattern = re.compile(r"GoogleMobileAds|googleads/swift-package-manager-google-mobile-ads|BannerAdView|InlineFeedAdView")
files = [root / "project.yml", root / "LovelyMusic.xcodeproj/project.pbxproj"]
files.extend((root / "LovelyMusic").rglob("*.swift"))
matches = [str(path.relative_to(root)) for path in files if ad_pattern.search(path.read_text(encoding="utf-8"))]
assert not matches, f"Advertising SDK/view references remain: {', '.join(matches)}"

with (root / "LovelyMusic/Resources/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert "GADApplicationIdentifier" not in info, "AdMob application ID remains"
assert "SKAdNetworkItems" not in info, "Advertising attribution identifiers remain"
assert not re.search(r"GADApplicationIdentifier|SKAdNetworkItems", (root / "project.yml").read_text(encoding="utf-8"))

print("PASS: iOS has no advertising SDK or attribution configuration")
