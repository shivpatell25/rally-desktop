#!/usr/bin/env python3
"""Assemble a local app from an already built SwiftPM product."""
from pathlib import Path
import argparse
import plistlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--configuration", choices=["debug", "release"], default="release")
parser.add_argument("--version", default="0.6.0")
parser.add_argument("--output", default="dist-native/Rally.app")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / ".build" / args.configuration
app = root / args.output
contents = app / "Contents"
for directory in ["MacOS", "Resources", "Frameworks"]:
    (contents / directory).mkdir(parents=True, exist_ok=True)
shutil.copy2(products / "RallyDesktop", contents / "MacOS" / "RallyDesktop")
for name in ["VLCKit", "Sparkle"]:
    target = contents / "Frameworks" / f"{name}.framework"
    # Generated framework bundles must be replaced together with their version symlinks.
    if target.exists():
        shutil.rmtree(target)
    framework = products / f"{name}.framework"
    if not framework.exists():
        matches = list((root / ".build/artifacts").glob(f"**/macos-*/{name}.framework"))
        if len(matches) != 1:
            raise RuntimeError(f"Cannot locate the macOS {name} framework")
        framework = matches[0]
    shutil.copytree(framework, target, symlinks=True)
shutil.copytree(products / "RallyDesktop_RallyCore.bundle", contents / "Resources" / "RallyDesktop_RallyCore.bundle", dirs_exist_ok=True)
# Build the official icon directly, including on a clean checkout.
source_icon = root.parent / "Rally_Brand_Kit/05_App_Icons/rally_app_icon_1024x1024.png"
with tempfile.TemporaryDirectory(prefix="RallyIcon-") as temporary:
    iconset = Path(temporary) / "AppIcon.iconset"; iconset.mkdir()
    for size in [16, 32, 128, 256, 512]:
        for factor in [1, 2]:
            suffix = "@2x" if factor == 2 else ""
            output = iconset / f"icon_{size}x{size}{suffix}.png"
            subprocess.run(["sips", "-z", str(size * factor), str(size * factor), str(source_icon), "--out", str(output)], check=True, capture_output=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(contents / "Resources/AppIcon.icns")], check=True)
info = plistlib.loads((root / "packaging/Info.plist").read_bytes())
info["CFBundleShortVersionString"] = args.version
info["CFBundleVersion"] = "6"
info["LSApplicationCategoryType"] = "public.app-category.sports"
info["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
info["SUPublicEDKey"] = (root / "sparkle_public_key.txt").read_text().strip()
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(contents / "MacOS/RallyDesktop")], capture_output=True)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
