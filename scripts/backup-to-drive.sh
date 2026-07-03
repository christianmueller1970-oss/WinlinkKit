#!/bin/zsh
# 1:1 backup of the WinlinkKit repo to Google Drive (07-WinLinkKit).
# Run after each work session. Git history goes into a single bundle file
# instead of syncing thousands of .git object files through Drive.
set -euo pipefail

SRC="$HOME/Developer/WinlinkKit"
DST="/Users/chris/Library/CloudStorage/GoogleDrive-christian.mueller1970@gmail.com/Meine Ablage/04_Projekte/05_AFU_Projekte/07-WinLinkKit"
MEMORY_SRC="$HOME/.claude/projects/-Users-chris-Library-CloudStorage-GoogleDrive-christian-mueller1970-gmail-com-Meine-Ablage-04-Projekte-05-AFU-Projekte-07-WinLinkKit/memory"

# Working tree (without build artifacts, reference clone and .git)
rsync -a --delete \
  --exclude '.build' --exclude '.swiftpm' --exclude 'reference' --exclude '.git' \
  "$SRC/" "$DST/WinlinkKit/"

# Complete git history as a single restorable file
# (restore with: git clone WinlinkKit.gitbundle WinlinkKit)
git -C "$SRC" bundle create "$DST/WinlinkKit.gitbundle" --all

# Claude Code memories
rsync -a --delete "$MEMORY_SRC/" "$DST/claude-memory/"

echo "Backup complete: $(date '+%Y-%m-%d %H:%M')"
