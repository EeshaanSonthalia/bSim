#!/bin/sh

set -eu
LC_ALL=C
export LC_ALL
. "$(dirname -- "$0")/common.sh"

root=$(repo_root)
docs_root="$root/docs"
violations=0
files_checked=0

fail() {
  printf 'error: %s\n' "$*" >&2
  violations=$((violations + 1))
}

md_files() {
  find "$docs_root" -type f -name '*.md' -print | sort
}

rel() {
  printf '%s' "${1#"$root"/}"
}

is_snippet() {
  case "$(rel "$1")" in
    docs/shared/snippets/*) return 0 ;;
    *) return 1 ;;
  esac
}

slice_frontmatter() {
  awk '
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { exit }
    in_fm { print }
  ' "$1"
}

prose_lines() {
  awk '
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; next }
    in_fm { next }
    /^```/ { in_code = !in_code; next }
    in_code { next }
    /^#{1,6}[[:space:]]/ { next }
    /^[[:space:]]*\|/ { next }
    /^\[[^]]+\]:[[:space:]]/ { next }
    {
      line = $0
      gsub(/`[^`]*`/, "CODE", line)
      gsub(/\]\([^)]*\)/, "]", line)
      gsub(/https?:\/\/[^[:space:])>]+/, "URL", line)
      print NR "\t" line
    }
  ' "$1"
}

check_file_hygiene() {
  file=$1
  relfile=$2
  out=$3
  : >"$out"

  if grep -nE '[[:blank:]]+$' "$file" >"$out"; then
    while IFS= read -r line; do fail "$relfile: trailing whitespace: $line"; done <"$out"
  fi

  tab=$(printf '\t')
  if grep -n "$tab" "$file" >"$out"; then
    while IFS= read -r line; do fail "$relfile: tab character is not permitted: $line"; done <"$out"
  fi

  cr=$(printf '\r')
  if grep -n "$cr" "$file" >"$out"; then
    while IFS= read -r line; do fail "$relfile: carriage return is not permitted: $line"; done <"$out"
  fi

  last_byte=$(tail -c 1 "$file" | od -An -t x1 | tr -d '[:space:]')
  [ "$last_byte" = 0a ] || fail "$relfile: file must end with one newline"
}

check_filename() {
  file=$1
  relfile=$2
  base=${relfile##*/}

  case "$relfile" in
    docs/modules/concepts/*)
      case "$base" in concept[A-Z]*.md) ;; *) fail "$relfile: concept module name must use conceptCamelCase.md" ;; esac
      ;;
    docs/modules/procedures/*)
      case "$base" in proc[A-Z]*.md) ;; *) fail "$relfile: procedure module name must use procCamelCase.md" ;; esac
      ;;
    docs/modules/references/*)
      case "$base" in ref[A-Z]*.md) ;; *) fail "$relfile: reference module name must use refCamelCase.md" ;; esac
      ;;
    docs/assemblies/*)
      case "$base" in assembly[A-Z]*.md) ;; *) fail "$relfile: assembly name must use assemblyCamelCase.md" ;; esac
      ;;
  esac
}

check_frontmatter() {
  file=$1
  relfile=$2
  out=$3

  if is_snippet "$file"; then
    return 0
  fi

  first_line=$(sed -n '1p' "$file")
  [ "$first_line" = '---' ] || fail "$relfile: first line must start YAML frontmatter"

  delimiter_count=$(awk '
    NR == 1 && /^---$/ { in_fm = 1; count = 1; next }
    in_fm && /^---$/ { count++; exit }
    END { print count + 0 }
  ' "$file")
  [ "$delimiter_count" -eq 2 ] || fail "$relfile: frontmatter must have exactly two delimiter lines"

  fm=$(slice_frontmatter "$file")
  for key in title description audience stability last-reviewed ms.topic; do
    if ! printf '%s\n' "$fm" | grep -Eq "^${key}:[[:space:]]*[^[:space:]]"; then
      fail "$relfile: frontmatter key is missing or empty: $key"
    fi
  done

  printf '%s\n' "$fm" | awk -F: '
    /^[A-Za-z0-9_.-]+:/ {
      if (++seen[$1] > 1) print "duplicate frontmatter key: " $1
    }
  ' >"$out"
  if [ -s "$out" ]; then
    while IFS= read -r line; do fail "$relfile: $line"; done <"$out"
  fi

  reviewed=$(printf '%s\n' "$fm" | sed -n 's/^last-reviewed:[[:space:]]*//p')
  case "$reviewed" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail "$relfile: last-reviewed must use YYYY-MM-DD" ;;
  esac
  today=$(date -u +%Y-%m-%d | tr -d '-')
  reviewed_number=$(printf '%s' "$reviewed" | tr -d '-')
  case "$reviewed_number" in
    ''|*[!0-9]*) ;;
    *) [ "$reviewed_number" -le "$today" ] || fail "$relfile: last-reviewed cannot be in the future" ;;
  esac

  stability=$(printf '%s\n' "$fm" | sed -n 's/^stability:[[:space:]]*//p')
  case "$stability" in stable|evolving|scratch) ;; *) fail "$relfile: stability must be stable, evolving, or scratch" ;; esac

  audience=$(printf '%s\n' "$fm" | sed -n 's/^audience:[[:space:]]*//p')
  case "$audience" in
    '[humans]'|'[agents]'|'[humans, agents]') ;;
    *) fail "$relfile: audience must be [humans], [agents], or [humans, agents]" ;;
  esac

  topic=$(printf '%s\n' "$fm" | sed -n 's/^ms\.topic:[[:space:]]*//p')
  case "$topic" in
    overview|concept|tutorial|reference|how-to|troubleshooting|guide|prompt) ;;
    *) fail "$relfile: unsupported ms.topic: $topic" ;;
  esac

  estimated=$(printf '%s\n' "$fm" | sed -n 's/^estimated_reading_time:[[:space:]]*//p')
  if [ -n "$estimated" ]; then
    case "$estimated" in *[!0-9]*) fail "$relfile: estimated_reading_time must be an integer" ;; esac
  fi
}

check_headings() {
  file=$1
  relfile=$2
  out=$3
  snippet=0
  is_snippet "$file" && snippet=1

  awk -v relfile="$relfile" -v out="$out" -v snippet="$snippet" '
    function bad(message) { print relfile ":" NR ": " message > out }
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; next }
    in_fm { next }
    /^```[[:alnum:]_-]*[[:space:]]*$/ {
      in_code = !in_code
      next
    }
    /^```/ { bad("code fence must be ``` or ```language"); next }
    in_code { next }
    /^[[:space:]]*$/ { next }
    {
      if (!first_content_seen) {
        first_content_seen = 1
        if (!snippet && $0 !~ /^#{1,6}[[:space:]]/) bad("first body content must be a heading")
      }
      if ($0 !~ /^#{1,6}[[:space:]]/) next
      hashes = $0
      sub(/[[:space:]].*$/, "", hashes)
      level = length(hashes)
      heading = $0
      sub(/^#{1,6}[[:space:]]+/, "", heading)
      if (heading == "") bad("heading text is empty")
      if (previous_level > 0 && level > previous_level + 1) bad("heading level skips from " previous_level " to " level)
      previous_level = level
      if (level == 1) {
        h1_count++
        if (h1_count == 1 && heading !~ /[[:space:]]\{#[a-z0-9-]+\}[[:space:]]*$/) bad("H1 has no valid explicit anchor")
      }
      if (heading ~ /[[:space:]]\{#[^}]+\}[[:space:]]*$/) {
        anchor = heading
        sub(/^.*\{#/, "", anchor)
        sub(/\}[[:space:]]*$/, "", anchor)
        if (anchor !~ /^[a-z0-9-]+$/) bad("heading anchor is not lowercase kebab-case: " anchor)
        if (++anchors[anchor] > 1) bad("duplicate heading anchor: " anchor)
      }
    }
    END {
      if (in_code) bad("unclosed code fence")
      if (!snippet && h1_count != 1) bad("document must have exactly one H1")
      if (!snippet && h1_count == 0) bad("document has no H1")
    }
  ' "$file"
}

check_tldr() {
  file=$1
  relfile=$2
  out=$3
  is_snippet "$file" && return 0

  tldr_stats=$(awk '
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; next }
    in_fm { next }
    /^```/ { in_code = !in_code; next }
    in_code { next }
    /^[[:space:]]*\*\*TL;DR\.\*\*/ { count++; if (!found) { found = 1; tldr_line = NR } }
    END { print count + 0, tldr_line + 0 }
  ' "$file")
  count=$(printf '%s\n' "$tldr_stats" | cut -d' ' -f1)
  tldr_line=$(printf '%s\n' "$tldr_stats" | cut -d' ' -f2)
  [ "$count" -eq 1 ] || fail "$relfile: document must have exactly one **TL;DR.** label"

  first_body=$(awk '
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; next }
    in_fm { next }
    /^```/ { in_code = !in_code; next }
    in_code { next }
    /^# / { h1 = 1; next }
    h1 && $0 !~ /^[[:space:]]*$/ { print; exit }
  ' "$file")
  case "$first_body" in
    '**TL;DR.**'*) ;;
    *) fail "$relfile: TLDR must be the first body paragraph after H1" ;;
  esac

  tldr=$(awk '
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; next }
    in_fm { next }
    /^```/ { in_code = !in_code; next }
    in_code { next }
    /^\*\*TL;DR\.\*\*/ {
      in_tldr = 1
      sub(/^\*\*TL;DR\.\*\*[[:space:]]*/, "")
      print
      next
    }
    in_tldr && (/^[[:space:]]*$/ || /^##[[:space:]]/) { exit }
    in_tldr { print }
  ' "$file")
  words=$(printf '%s\n' "$tldr" | tr -s '[:space:]' '\n' | grep -c '.' || true)
  [ "$words" -le 75 ] || fail "$relfile: TLDR exceeds 75 words ($words)"
  if printf '%s\n' "$tldr" | grep -Fq ']('; then
    fail "$relfile: TLDR must not contain a Markdown link"
  fi
  [ "$tldr_line" -gt 0 ] || fail "$relfile: TLDR line could not be located"
}

check_related_pages() {
  file=$1
  relfile=$2
  out=$3
  case "$relfile" in
    docs/modules/*) ;;
    *) return 0 ;;
  esac

  awk -v relfile="$relfile" -v out="$out" '
    function report(message) { print relfile ": " message > out }
    /^## Related Pages[[:space:]]*$/ {
      count++
      in_related = 1
      next
    }
    in_related && /^[[:space:]]*$/ { next }
    in_related && /^- \[[^]]+\]\([^)]*\)[[:space:]]*$/ { links++; next }
    in_related { invalid_tail = 1 }
    END {
      if (count != 1) report("module must have exactly one Related Pages section")
      if (links == 0) report("Related Pages must contain at least one link")
      if (invalid_tail) report("Related Pages must be the final section and contain only links")
    }
  ' "$file"
}

check_style() {
  file=$1
  relfile=$2
  out=$3
  prose_lines "$file" | awk -F '\t' -v relfile="$relfile" -v out="$out" '
    {
      line_no = $1
      line = $0
      sub(/^[^\t]*\t/, "", line)
      gsub(/TL;DR/, "TLDR", line)
      low = tolower(line)
      if (index(line, ";") > 0) bad(line_no, "semicolon is not permitted in body text")
      if (index(line, "\047") > 0 || index(line, "\342\200\231") > 0) bad(line_no, "apostrophe is not permitted in body text")
      if (low ~ /(^|[^[:alpha:]])e[.]g[.]([^[:alpha:]]|$)/ || low ~ /(^|[^[:alpha:]])i[.]e[.]([^[:alpha:]]|$)/ || low ~ /(^|[^[:alpha:]])etc[.]([^[:alpha:]]|$)/) bad(line_no, "Latin abbreviation is not permitted")
      if (low ~ /(^|[^[:alpha:]])ensure([^[:alpha:]]|$)/) bad(line_no, "use make sure that instead of ensure")
      if (low ~ /(^|[^[:alpha:]])utili[sz]/) bad(line_no, "use a direct verb instead of utilize")
      if (low ~ /(^|[^[:alpha:]])via([^[:alpha:]]|$)/) bad(line_no, "use with or through instead of via")
      if (low ~ /prior[[:space:]]+to/) bad(line_no, "use before instead of prior to")
      if (low ~ /in[[:space:]]+order[[:space:]]+to/) bad(line_no, "use to instead of in order to")
      if (low ~ /(^|[^[:alpha:]])commenc/) bad(line_no, "use start instead of commence")
      if (low ~ /(^|[^[:alpha:]])and\/or([^[:alpha:]]|$)/) bad(line_no, "write the exact relationship instead of and/or")
      if (low ~ /(^|[^[:alpha:]])(colour|favour|favourite|behaviour|neighbour|honour|labour|organised|organises|organisation|analyse|analysed|centre|fibre|litre|metre|defence|offence)([^[:alpha:]]|$)/) bad(line_no, "use American English spelling")
      if (line ~ /[^[:space:]][[:space:]][[:space:]]+[^[:space:]]/) bad(line_no, "multiple consecutive spaces are not permitted")
      if (line ~ /!!|\?\?|\.\.\./) bad(line_no, "repeated punctuation is not permitted")
    }
    function bad(line_no, message) {
      printf "%s:%s: %s\n", relfile, line_no, message > out
    }
  '
}

check_sentence_length() {
  file=$1
  relfile=$2
  out=$3
  limit=25
  case "$relfile" in docs/modules/procedures/*) limit=20 ;; esac

  awk -v relfile="$relfile" -v out="$out" -v limit="$limit" '
    function clean(value) {
      gsub(/`[^`]*`/, "CODE", value)
      gsub(/\[[^]]*\]\([^)]*\)/, "LINK", value)
      gsub(/https?:\/\/[^[:space:])>]+/, "URL", value)
      gsub(/\([^)]*\)/, "PAREN", value)
      gsub(/[[:space:]]+/, " ", value)
      return value
    }
    function word_count(value, count, words) {
      value = clean(value)
      gsub(/[^[:alnum:]_-]+/, " ", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value == "") return 0
      count = split(value, words, /[[:space:]]+/)
      return count
    }
    function report_sentence(start_line, count) {
      if (count > limit) printf "%s:%s: sentence has %s words, maximum is %s\n", relfile, start_line, count, limit > out
    }
    function flush(    value, count, parts, i, words) {
      if (paragraph == "") return
      value = clean(paragraph)
      count = split(value, parts, /[.!?][[:space:]]+/)
      if (count > 6) printf "%s:%s: paragraph has %s sentences, maximum is 6\n", relfile, paragraph_line, count > out
      for (i = 1; i <= count; i++) {
        words = word_count(parts[i])
        report_sentence(paragraph_line, words)
      }
      paragraph = ""
      paragraph_line = 0
    }
    function append(value, line_no) {
      if (paragraph == "") paragraph_line = line_no
      if (paragraph != "") paragraph = paragraph " "
      paragraph = paragraph value
    }
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; next }
    in_fm { next }
    /^```/ { flush(); in_code = !in_code; next }
    in_code { next }
    /^[[:space:]]*$/ { flush(); next }
    /^#{1,6}[[:space:]]/ { flush(); next }
    /^[[:space:]]*\|/ { flush(); next }
    /^---+[[:space:]]*$/ { flush(); next }
    /^[[:space:]]*([-*+][[:space:]]|[0-9]+\.[[:space:]])/ {
      flush()
      append($0, NR)
      flush()
      next
    }
    { append($0, NR) }
    END { flush() }
  ' "$file"
}

check_procedure_items() {
  file=$1
  relfile=$2
  out=$3
  case "$relfile" in docs/modules/procedures/*) ;; *) return 0 ;; esac

  awk -v relfile="$relfile" -v out="$out" '
    function bad(message) { print relfile ":" NR ": " message > out }
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; next }
    in_fm { next }
    /^```/ { in_code = !in_code; next }
    in_code { next }
    /^[[:space:]]*[0-9]+\.[[:space:]]+/ {
      item = $0
      sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", item)
      gsub(/^[[:space:]*_`]+/, "", item)
      if (item ~ /^(The|A|An|It|This|That|These|Those|There)([[:space:][:punct:]]|$)/) bad("ordered procedure item must start with an imperative command")
      if (item ~ /^(If|When|After|Before|Once|Unless|While)([[:space:]]|$)/ && item !~ /^[^,]*,/) bad("condition must end with a comma before the command")
    }
  ' "$file"
}

check_links() {
  file=$1
  relfile=$2
  out=$3
  dir=$(dirname -- "$file")
  inline=$(grep -oE '\]\([^)]+\)' "$file" | sed -E 's/^\]\(//; s/\)$//' || true)
  reference_style=$(grep -E '^\[[^]]+\]:' "$file" | sed -E 's/^\[[^]]+\]:[[:space:]]*//' || true)
  {
    printf '%s\n' "$inline"
    printf '%s\n' "$reference_style"
  } | while IFS= read -r target; do
    [ -n "$target" ] || continue
    case "$target" in http://*) printf '%s: insecure HTTP link: %s\n' "$relfile" "$target"; continue ;; esac
    strip_anchor=${target%%#*}
    strip_query=${strip_anchor%%\?*}
    case "$strip_query" in
      https://*|mailto:*|tel:*|'#'*) continue ;;
    esac
    [ -n "$strip_query" ] || continue
    if [ ! -e "$dir/$strip_query" ]; then
      printf '%s: broken link target: %s\n' "$relfile" "$target"
      continue
    fi
    case "$target" in
      *\#*)
        anchor=${target#*\#}
        if ! grep -Fq "{#$anchor}" "$dir/$strip_query"; then
          slugs=$(awk '
            /^```/ { in_code = !in_code; next }
            in_code { next }
            /^#{1,6}[[:space:]]/ {
              line = $0
              sub(/^#{1,6}[[:space:]]+/, "", line)
              sub(/[[:space:]]+\{#.*\}[[:space:]]*$/, "", line)
              gsub(/[^A-Za-z0-9 ]+/, "", line)
              gsub(/[[:space:]]+/, "-", line)
              print tolower(line)
            }
          ' "$dir/$strip_query")
          found=0
          while IFS= read -r slug; do
            [ "$slug" = "$anchor" ] && found=1
          done <<EOF
$slugs
EOF
          [ "$found" -eq 1 ] || printf '%s: link anchor not found: %s\n' "$relfile" "$target"
        fi
        ;;
    esac
  done >"$out"
}

check_adr_length() {
  for file in "$docs_root"/adr/*.md; do
    [ -e "$file" ] || continue
    case "$(basename -- "$file")" in DECISIONS.md) continue ;; esac
    relfile=$(rel "$file")
    lines=$(wc -l <"$file" | tr -d ' ')
    [ "$lines" -le 150 ] || fail "$relfile: ADR exceeds 150 lines ($lines)"
    for heading in Status Context Decision Consequences; do
      grep -Eq "^## $heading[[:space:]]*$" "$file" || fail "$relfile: ADR section is missing: $heading"
    done
  done
}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/asd-docs.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT INT TERM

for file in $(md_files); do
  files_checked=$((files_checked + 1))
  relfile=$(rel "$file")
  file_id=$files_checked
  check_filename "$file" "$relfile"
  check_file_hygiene "$file" "$relfile" "$tmpdir/hygiene-$file_id"
  check_frontmatter "$file" "$relfile" "$tmpdir/frontmatter-$file_id"
  check_headings "$file" "$relfile" "$tmpdir/headings-$file_id"
  check_tldr "$file" "$relfile" "$tmpdir/tldr-$file_id"
  check_related_pages "$file" "$relfile" "$tmpdir/related-$file_id"
  check_style "$file" "$relfile" "$tmpdir/style-$file_id"
  check_sentence_length "$file" "$relfile" "$tmpdir/sentences-$file_id"
  check_procedure_items "$file" "$relfile" "$tmpdir/procedure-$file_id"
  check_links "$file" "$relfile" "$tmpdir/links-$file_id"
  for report in "$tmpdir"/*-"$file_id"; do
    [ -s "$report" ] || continue
    while IFS= read -r line; do fail "$line"; done <"$report"
  done
done

check_adr_length

printf 'docs check: %d file(s) checked, %d violation(s)\n' "$files_checked" "$violations"
[ "$violations" -eq 0 ] || exit 1
printf 'docs check: structural and style checks passed. Review vocabulary and meaning against Issue 9.\n'
