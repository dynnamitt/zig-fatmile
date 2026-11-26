#!/bin/sh
# showel.svg → src/render/shovel.png, the mouse pointer: recoloured to one
# hue of the theme (sand, as src/core/palette.zig), turned 45° clockwise
# (blade down-left), shrunk to a pixel sprite with a 1 px outline.
# Needs ImageMagick 7 with librsvg. Run from anywhere; rerun after editing
# showel.svg. The game finds the blade tip (the pointer's hotspot) itself.
set -eu
cd "$(dirname "$0")"

SIZE=32 # sprite side in px, outline included
TURN=45 # degrees clockwise
# Fills in showel.svg → shades of palette.sand.
GRIP=a08660 HANDLE=e8dcb8 BLADE=c8a878 BLADE_SHADE=786548
OUTLINE=071816 # palette.line
OUT=../src/render/shovel.png

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Recolour; drop the thin strokes, the outline is added in pixels below.
sed -e "s/#8800aa/#$GRIP/g; s/#a7ac93/#$HANDLE/g; s/#800000/#$BLADE/g; s/#501616/#$BLADE_SHADE/g" \
    -e 's/stroke:#000000/stroke:none/g' showel.svg >"$tmp/mono.svg"

magick xc:"#$GRIP" xc:"#$HANDLE" xc:"#$BLADE" xc:"#$BLADE_SHADE" +append "$tmp/pal.png"

magick -background none -density 300 "$tmp/mono.svg" -rotate $TURN -trim +repage \
    -resize $((SIZE - 2))x$((SIZE - 2)) -channel A -threshold 50% +channel -write mpr:src \
    +dither -remap "$tmp/pal.png" \
    \( mpr:src -alpha extract \) -alpha off -compose CopyOpacity -composite -compose Over \
    -bordercolor none -border 1 \
    \( +clone -alpha extract -morphology dilate square:1 \
       -background "#$OUTLINE" -alpha shape \) \
    +swap -composite -gravity center -background none -extent ${SIZE}x${SIZE} \
    -strip "PNG32:$OUT"

