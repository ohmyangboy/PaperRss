#!/usr/bin/env python3
import sys
import os
import subprocess
import shutil

def apply_icon(source_png):
    if not os.path.exists(source_png):
        print(f"Error: Source file {source_png} does not exist.")
        sys.exit(1)

    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    appiconset_dir = os.path.join(project_root, "PaperRss/Resources/Assets.xcassets/AppIcon.appiconset")
    icns_path = os.path.join(project_root, "PaperRss/Resources/AppIcon.icns")
    precomposed_icon = os.path.join(project_root, "build/app-icon-precomposed-1024.png")

    os.makedirs(os.path.dirname(precomposed_icon), exist_ok=True)
    subprocess.run([
        "swift",
        os.path.join(project_root, "scripts/render_macos_app_icon.swift"),
        os.path.abspath(source_png),
        precomposed_icon,
    ], check=True)

    # Specific sizes for iconutil .iconset
    iconset_specs = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    # Generate images for AppIcon.appiconset
    for filename, dim in iconset_specs.items():
        out_path = os.path.join(appiconset_dir, filename)
        cmd = ["sips", "-s", "format", "png", "-z", str(dim), str(dim), precomposed_icon, "--out", out_path]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    # iOS marketing icon must remain an opaque, full-bleed square. Only the
    # macOS idiom receives the inset transparent rounded composition above.
    cmd_1024 = ["sips", "-s", "format", "png", "-z", "1024", "1024", source_png, "--out", os.path.join(appiconset_dir, "icon_1024x1024.png")]
    subprocess.run(cmd_1024, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    # Build AppIcon.icns using iconutil
    iconset_temp = os.path.join(project_root, "build/AppIcon.iconset")
    if os.path.exists(iconset_temp):
        shutil.rmtree(iconset_temp)
    os.makedirs(iconset_temp, exist_ok=True)

    for name in iconset_specs.keys():
        shutil.copyfile(os.path.join(appiconset_dir, name), os.path.join(iconset_temp, name))

    cmd_icns = ["iconutil", "-c", "icns", iconset_temp, "-o", icns_path]
    subprocess.run(cmd_icns, check=True)

    print(f"✅ Successfully updated AppIcon.appiconset and AppIcon.icns!")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 apply_icon.py <path_to_source_png>")
        sys.exit(1)
    apply_icon(sys.argv[1])
