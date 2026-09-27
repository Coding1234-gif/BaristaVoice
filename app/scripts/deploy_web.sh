#!/usr/bin/env bash
# Builds the web app and publishes it to GitHub Pages (the `gh-pages` branch)
# at https://coding1234-gif.github.io/BaristaVoice — see README "Deploying the
# web build". Only the built site goes to gh-pages; `main` is untouched.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-$(command -v flutter || echo /Applications/flutter/bin/flutter)}"
REMOTE="$(git -C "$APP_DIR" remote get-url origin)"

cd "$APP_DIR"
# Pages serves a project site from /<repo>/, not the domain root.
"$FLUTTER" build web --release --base-href /BaristaVoice/

# Pages has no rewrite rules: any unknown path (e.g. a scanned /cafe/<id>
# QR link) gets 404.html — make that the app itself so the router takes over.
cp build/web/index.html build/web/404.html
# Stop Pages running the output through Jekyll.
touch build/web/.nojekyll

PUBLISH_DIR="$(mktemp -d)"
trap 'rm -rf "$PUBLISH_DIR"' EXIT
cp -R build/web/. "$PUBLISH_DIR"
cd "$PUBLISH_DIR"
git init -q -b gh-pages
git add -A
git commit -q -m "Deploy web build from $(git -C "$APP_DIR" rev-parse --short HEAD)"
git push -f "$REMOTE" gh-pages
echo "Published: https://coding1234-gif.github.io/BaristaVoice/"
