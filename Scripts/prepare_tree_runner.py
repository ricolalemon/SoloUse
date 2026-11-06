#!/usr/bin/env python3
"""Stage/sign an Xcode-built companion with the user's own local signing assets.

Apple frameworks are copied from the selected Xcode, never downloaded or added
to the source archive. The input application and profile are left untouched.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(*command):
    return subprocess.check_output(command, stderr=subprocess.STDOUT, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("built_app", type=Path)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--identity", required=True, help="Local codesign identity name or fingerprint")
    parser.add_argument("--output", required=True, type=Path, help="New output .app directory (must not exist)")
    args = parser.parse_args()
    source, output = args.built_app.resolve(), args.output.resolve()
    if output.exists() or output == source:
        parser.error("Output must be a new directory")
    info = plistlib.loads((source / "Info.plist").read_bytes())
    profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(args.profile)], stderr=subprocess.DEVNULL))
    grants = profile["Entitlements"]
    app_id = grants.get("application-identifier", "")
    if not app_id.endswith("." + info["CFBundleIdentifier"]):
        parser.error("Use a development profile for this exact runner bundle identifier")
    developer = Path(run("xcode-select", "-p").strip())
    platform = developer / "Platforms/iPhoneOS.platform/Developer"
    search = [platform / "Library/Frameworks", platform / "Library/PrivateFrameworks", platform / "usr/lib"]
    shutil.copytree(source, output, copy_function=shutil.copy)
    frameworks = output / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    queue = [output / info["CFBundleExecutable"]]
    for plugin in (output / "PlugIns").glob("*.xctest"):
        plugin_info = plistlib.loads((plugin / "Info.plist").read_bytes())
        queue.append(plugin / plugin_info["CFBundleExecutable"])
    seen = set()
    while queue:
        for line in run("otool", "-L", str(queue.pop())).splitlines()[1:]:
            library = line.strip().split(" (")[0]
            if not library.startswith("@rpath/"):
                continue
            relative = library.removeprefix("@rpath/")
            name = relative.split("/")[0]
            if name in seen:
                continue
            seen.add(name)
            if (frameworks / relative).exists():
                queue.append(frameworks / relative)
                continue
            item = next((root / name for root in search if (root / name).exists()), None)
            if item is None:
                raise RuntimeError(f"Required testing dependency missing from selected Xcode: {name}")
            target = frameworks / name
            if item.is_dir():
                shutil.copytree(item, target, copy_function=shutil.copy)
            else:
                shutil.copy(item, target)
            queue.append(frameworks / relative)
    shutil.copy(args.profile, output / "embedded.mobileprovision")
    entitlements = {key: grants[key] for key in ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow"] if key in grants}
    entitlements["keychain-access-groups"] = [app_id]
    entitlement_file = output.parent / (output.name + ".signing.plist")
    entitlement_file.write_bytes(plistlib.dumps(entitlements))
    try:
        for nested in sorted(output.rglob("*"), key=lambda p: len(p.parts), reverse=True):
            if nested.suffix in [".dylib", ".framework", ".xctest"]:
                run("codesign", "--force", "--sign", args.identity, "--timestamp=none", str(nested))
        run("codesign", "--force", "--sign", args.identity, "--entitlements", str(entitlement_file),
            "--generate-entitlement-der", "--timestamp=none", str(output))
        run("codesign", "--verify", "--deep", "--strict", str(output))
    finally:
        entitlement_file.unlink(missing_ok=True)
    print(output)


if __name__ == "__main__":
    main()
