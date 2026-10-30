#!/bin/bash
# Contact sheet of screenshots: sheet.sh out.png in1.png in2.png ... (cropped to the popup area)
out="$1"; shift
magick montage "$@" -crop 1264x1180+0+250 +repage -resize 50% -tile 3x -geometry +6+6 -background '#888' "$out"
echo "$out"
