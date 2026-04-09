#!/usr/bin/env bash

count=0
tmp=$(mktemp)

cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

while IFS= read -r -d '' file; do
  count=$((count + 1))
  lines=$(wc -l < "$file")
  if [ "$lines" -ge 800 ]; then
    rel=${file#./}
    printf '%s\t%s\n' "$lines" "$rel" >> "$tmp"
  fi
done < <(
  find . \( -type d \( -name '.tox' -o -name '.venv' \) -prune \) -o -type f -name '*.py' -print0
)

if [ -s "$tmp" ]; then
  sort -nr -k1,1 "$tmp" | awk -F '\t' '{ printf "%s : %s\n", $2, $1 }'
else
  echo "there are no long python files (checked $count python files)"
fi
