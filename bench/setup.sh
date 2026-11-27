#!/bin/zsh
# One-time setup for the benchmark: Node 22+, FFmpeg on PATH, Xcode 26+.
set -e
cd "${0:A:h}"
# the test clip: 10 s, 1080x1920, noisy test pattern with a tone
mkdir -p remotion/public hyperframes/video/assets
[ -f remotion/public/clip.mp4 ] || ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1080x1920:rate=30:duration=10" -f lavfi -i "sine=frequency=440:duration=10" \
  -vf "noise=alls=12:allf=t" -c:v libx264 -pix_fmt yuv420p -b:v 8M -c:a aac -shortest remotion/public/clip.mp4
cp remotion/public/clip.mp4 hyperframes/video/assets/clip.mp4
# Remotion + Kinetograph
(cd remotion && [ -f package.json ] || npm init -y >/dev/null; npm i remotion@4 @remotion/cli@4 react@19 react-dom@19 kinetograph@0.3)
# HyperFrames + GSAP (the pages load gsap.min.js from their own folder)
(cd hyperframes && [ -f package.json ] || npm init -y >/dev/null; npm i hyperframes@0.9 kinetograph@0.3 gsap@3.15.0)
for d in title cards video; do cp hyperframes/node_modules/gsap/dist/gsap.min.js hyperframes/$d/; done
# Sprocket
(cd .. && swift build -c release --product sprocket-render)
echo "setup done"
