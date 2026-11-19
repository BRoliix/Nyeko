#!/bin/bash
# Publishes this repository's HEAD to the public BRoliix/Nyeko as one new commit: a snapshot of the files, never this
# repository's history (Kestrel's history holds Coucou's media, icons and sounds, which are Louis Raillé's).
#
#   scripts/nyeko-publish.sh ~/Nyeko "What changed"     # ~/Nyeko: a clone of github.com/BRoliix/Nyeko
#   cd ~/Nyeko && git push
#
# It never pushes by itself: look at `git -C ~/Nyeko show --stat` first.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?usage: scripts/nyeko-publish.sh <clone of BRoliix/Nyeko> [message]}"
MSG="${2:-Sync with Kestrel $(git -C "$SRC" rev-parse --short HEAD)}"

[ -d "$DEST/.git" ] || { echo "$DEST is not a git clone of BRoliix/Nyeko" >&2; exit 1; }
if ! git -C "$SRC" diff --quiet HEAD; then
  echo "Commit or stash your changes first: only committed files are published." >&2
  exit 1
fi

# Replace the published files with HEAD's tracked files.
git -C "$DEST" rm -rq --ignore-unmatch . >/dev/null 2>&1 || true
git -C "$DEST" clean -fdxq   # and anything left over that git does not track
git -C "$SRC" archive HEAD | tar -x -C "$DEST"

# Never public, even if an upstream merge brings them back: Coucou's media, site, design files and packaging.
rm -rf "$DEST/design" "$DEST/docs/media" "$DEST/docs/COUCOU-README.md" "$DEST/windows/screenshots" "$DEST/linux" \
  "$DEST/Casks" "$DEST/flake.nix" "$DEST/flake.lock" "$DEST/scripts/release.sh"
rm -f "$DEST"/docs/*.html "$DEST/docs/site.css"

git -C "$DEST" add -A
# Files this repository tracks although .gitignore matches them (test fixtures such as a test certificate).
git -C "$SRC" ls-files -ci --exclude-standard | while read -r f; do
  [ -e "$DEST/$f" ] && git -C "$DEST" add -f -- "$f"
done
if git -C "$DEST" diff --cached --quiet; then
  echo "Nothing new to publish."
  exit 0
fi

# Secrets: a scan of exactly what is about to be published, when gitleaks is installed.
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks dir "$DEST" --no-banner --redact || { echo "gitleaks found something: nothing committed." >&2; exit 1; }
fi

git -C "$DEST" commit -q -m "$MSG"
echo "Committed in $DEST: $(git -C "$DEST" log -1 --format='%h %s'). Check it, then: git -C \"$DEST\" push"
