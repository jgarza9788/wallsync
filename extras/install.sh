#!/bin/bash
# Wire jgarza.wallsync into the shell: enable the plugin, add a "Wallsync" row to
# the Omarchy menu (SUPER+SPACE), and drop an app-launcher entry. Idempotent.
set -e
here=$(cd "$(dirname "$0")" && pwd)

# 1. Enable the overlay plugin so `omarchy-shell shell toggle` will summon it.
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin enable jgarza.wallsync >/dev/null 2>&1 || true
fi

# 2. App-launcher entry.
mkdir -p ~/.local/share/applications
cp "$here/jgarza-wallsync.desktop" ~/.local/share/applications/
update-desktop-database ~/.local/share/applications 2>/dev/null || true

# 3. Omarchy menu entry — merge one line into the user extension file.
menu=~/.config/omarchy/extensions/omarchy-menu.jsonc
if [[ -f $menu ]] && grep -q '"wallsync"' "$menu"; then
  echo "menu entry already present"
else
  mkdir -p "$(dirname "$menu")"
  [[ -f $menu ]] || echo '{' > "$menu"
  tmp=$(mktemp)
  # Note the '\''{}'\'' — a literal single-quoted {} (empty JSON payload).
  entry='  "wallsync": {"icon":"󰸉","label":"Wallsync","aliases":["wallsync","wallpaper","background","palette","colors"],"description":"Pick a wallpaper and theme everything to match","action":"omarchy-shell shell toggle jgarza.wallsync '\''{}'\''"}'
  awk -v e="$entry" '
    { lines[NR]=$0 }
    END {
      last=NR; while (last>0 && lines[last] !~ /}/) last--
      prev=last-1; while (prev>0 && (lines[prev] ~ /^[[:space:]]*$/ || lines[prev] ~ /^[[:space:]]*\/\//)) prev--
      if (prev>0 && lines[prev] !~ /[{,][[:space:]]*$/) lines[prev]=lines[prev] ","
      for (i=1;i<last;i++) print lines[i]
      print e
      for (i=last;i<=NR;i++) print lines[i]
    }' "$menu" > "$tmp" && mv "$tmp" "$menu"
  echo "added Wallsync to the Omarchy menu"
fi

# 4. Re-parse the menu if the shell is up.
omarchy menu refresh >/dev/null 2>&1 || true

echo "done. Open it from the Omarchy menu (SUPER+SPACE -> Wallsync), the app launcher, or:"
echo "  omarchy-shell shell toggle jgarza.wallsync '{}'"
