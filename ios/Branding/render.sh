#!/usr/bin/env bash
# Regenerates every Lumisound icon asset from make_icon.py.
# Needs: python3, rsvg-convert, magick.
set -euo pipefail
cd "$(dirname "$0")"
python3 make_icon.py .
IOS=../Lumisound/Resources/Assets.xcassets
TV="../LumisoundTV/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
WATCH=../LumisoundWatch/Resources/Assets.xcassets

opaque() { rsvg-convert -w "$2" -h "$3" "$1" | magick - -background '#05030d' -alpha remove -alpha off "PNG24:$4"; }
alpha()  { rsvg-convert -w "$2" -h "$3" "$1" -o "$4"; }

opaque icon.svg 1024 1024 icon-1024.png
# iOS / iPadOS app icon
for spec in 20@1x:20 20@2x:40 20@3x:60 29@1x:29 29@2x:58 29@3x:87 40@1x:40 40@2x:80 40@3x:120 \
            60@2x:120 60@3x:180 76@1x:76 76@2x:152 83.5@2x:167; do
  n=${spec%%:*}; px=${spec##*:}
  magick icon-1024.png -filter Lanczos -resize ${px}x${px} "PNG24:$IOS/AppIcon.appiconset/Icon-$n.png"
done
cp icon-1024.png "$IOS/AppIcon.appiconset/Icon-1024.png"
cp icon-1024.png "$IOS/AppIconDisplay.imageset/AppIconDisplay.png"

# tvOS: two parallax layers + Top Shelf
opaque tv-back.svg 400 240 "$TV/App Icon.imagestack/Back.imagestacklayer/Content.imageset/img.png"
opaque tv-back.svg 800 480 "$TV/App Icon.imagestack/Back.imagestacklayer/Content.imageset/img@2x.png"
opaque tv-back.svg 1280 768 "$TV/App Icon - App Store.imagestack/Back.imagestacklayer/Content.imageset/img.png"
alpha tv-front.svg 400 240 "$TV/App Icon.imagestack/Front.imagestacklayer/Content.imageset/img.png"
alpha tv-front.svg 800 480 "$TV/App Icon.imagestack/Front.imagestacklayer/Content.imageset/img@2x.png"
alpha tv-front.svg 1280 768 "$TV/App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/img.png"
opaque tv-topshelf.svg 1920 720 "$TV/Top Shelf Image.imageset/img.png"
opaque tv-topshelf.svg 3840 1440 "$TV/Top Shelf Image.imageset/img@2x.png"
opaque tv-topshelf-wide.svg 2320 720 "$TV/Top Shelf Image Wide.imageset/img.png"
opaque tv-topshelf-wide.svg 4640 1440 "$TV/Top Shelf Image Wide.imageset/img@2x.png"

# watchOS (single-size icon, the system masks it to a circle)
mkdir -p "$WATCH/AppIcon.appiconset"
cp icon-1024.png "$WATCH/AppIcon.appiconset/Icon-1024.png"
echo done
