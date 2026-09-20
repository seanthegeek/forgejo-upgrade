#!/usr/bin/env bash
# Link checker for README.md, docs/*.md, AGENTS.md, CHANGELOG.md and
# forgejo-upgrade.sh, run by `make links`.
#
# For every https:// URL in these files it runs the four checks AGENTS.md's
# "Markdown style" section lists:
#   - the page must answer HTTP 200 (after redirects);
#   - a #fragment on an HTML page must match an element id on that page,
#     after percent-decoding;
#   - a #Lnn or #Lnn-Lmm fragment on a codeberg / code.forgejo.org / GitHub
#     blob URL is checked against the raw file at the same pin: the lines
#     must exist, and when the EXPECT table below names a phrase for that
#     path and line, the phrase must appear within those lines;
#   - a CVE record is checked through the MITRE API, whose description must
#     name Forgejo (cve.org itself is a single-page app that answers 200 for
#     any id).
# Two more checks are in the code but not in that list: a
# code.forgejo.org/api/swagger#/... fragment is checked against the real
# operationId in the published swagger spec, and every fetch sends a
# User-Agent, because a bare curl gets an empty body from some hosts (NVD
# among them).
#
# The cache lives under tmp/linkcache/, which this script creates and which
# never expires: `rm -rf tmp/linkcache` is how to force a refetch.
#
# Before a version is tagged and its release published, the three
# release-URL failures described under "Releases" in AGENTS.md are
# expected, not bugs in this script.
#
# Zero URLs found is a failure. Exit status is the number of failures.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 99
cache=tmp/linkcache; mkdir -p "$cache"
fail=0; ok=0

# phrases that must appear within the cited lines: "path#Lnn[-Lmm]|phrase"
EXPECT=(
  'modules/setting/path.go#L124|GITEA_WORK_DIR (work path) must be absolute path'
  'modules/setting/path.go#L132|FORGEJO_WORK_DIR (work path) must be absolute path'
  'modules/setting/path.go#L157|--work-path must be absolute path'
  'modules/setting/path.go#L192|WORK_PATH in %q must be absolute path'
  'modules/setting/path.go#L195-L199|SameFile'
  'modules/setting/path.go#L190|configWorkPath != ""'
  'modules/setting/path.go#L170|filepath.Abs'
  'modules/setting/path.go#L177-L178|readFromArgs()'
  'modules/setting/path.go#L189|WORK_PATH'
  'modules/setting/config_provider.go#L189-L194|configProviderLoadOptions'
  'modules/setting/config_provider.go#L293-L294|0o600'
  'modules/setting/security.go#L415-L430|INTERNAL_TOKEN'
  'modules/setting/packages.go#L72-L78|package-upload'
  'modules/private/internal.go#L56|unix'
  'modules/setting/server.go#L288-L304|LOCAL_ROOT_URL'
  'models/gitea_migrations/migrations.go#L489-L496|is for a newer Forgejo'
  'models/forgejo_migrations/migrate.go#L196|log.Fatal'
  'cmd/dump.go#L199-L229|skip-repository'
  'cmd/dump.go#L304|os.Create'
  'cmd/dump.go#L419-L421|0o600'
  'cmd/dump.go#L414|util.Remove'
  'cmd/dump.go#L334-L338|app.ini'
  'cmd/dump.go#L254-L260|CutSuffix'
  'cmd/web.go#L171|AppWorkPathMismatch'
  'cmd/main.go#L62-L73|work-path'
  'routers/web/web.go#L395|healthz'
  'routers/web/healthcheck/check.go#L67|func Check'
  'go.mod#L112|gopkg.in/ini.v1 v1.67.3'
  'contrib/systemd/forgejo.service#L56|User=git'
  'contrib/systemd/forgejo.service#L58|WorkingDirectory=/var/lib/forgejo'
  'contrib/systemd/forgejo.service#L62|ExecStart=/usr/local/bin/forgejo'
  'contrib/systemd/forgejo.service#L64|FORGEJO_WORK_DIR=/var/lib/forgejo'
  'internal/pkg/config/config.example.yaml#L23|file: .runner'
  'internal/pkg/config/config.example.yaml#L25|capacity'
  'internal/pkg/config/config.example.yaml#L38-L42|shutdown_timeout'
  'internal/pkg/config/config.example.yaml#L192-L196|network'
  'internal/pkg/config/config.example.yaml#L201|privileged'
  'internal/pkg/config/config.example.yaml#L220-L223|docker_host'
  'contrib/forgejo-runner.service#L7|ExecStart='
  'contrib/forgejo-runner.service#L11|User=runner'
  'contrib/forgejo-runner.service#L12|WorkingDirectory=/home/runner'
  'contrib/forgejo-runner.service#L15|TimeoutStopSec=infinity'
  'main.go#L16|SIGTERM'
  'internal/app/cmd/daemon.go#L93-L100|shutdown_timeout'
  'key.go#L142-L176|transformValue'
  'section.go#L66-L84|NewKey'
  'doc/DETAILS#L537|VALIDSIG'
  'doc/DETAILS#L485|EXPSIG'
  'doc/DETAILS#L492|EXPKEYSIG'
  'doc/DETAILS#L499|REVKEYSIG'
  'doc/DETAILS#L506|BADSIG'
  'doc/DETAILS#L521|ERRSIG'
  'doc/DETAILS#L815|KEYEXPIRED'
  'doc/DETAILS#L829|NO_PUBKEY'
)

fetch() {  # $1 = url -> file in cache, prints status
  local f
  f="$cache/$(printf '%s' "$1" | md5sum | cut -c1-32)"
  if [[ ! -s "$f.code" ]]; then
    curl -sL -A 'forgejo-upgrade-linkcheck/1.0' -o "$f" -w '%{http_code}' "$1" > "$f.code"
  fi
  printf '%s\n' "$f"
}

raw_url() {  # $1 = blob url without fragment -> raw url for the same file
  case "$1" in
    https://codeberg.org/*/src/commit/*)      printf '%s\n' "${1/\/src\/commit\//\/raw\/commit\/}" ;;
    https://codeberg.org/*/src/branch/*)      printf '%s\n' "${1/\/src\/branch\//\/raw\/branch\/}" ;;
    https://code.forgejo.org/*/src/commit/*)  printf '%s\n' "${1/\/src\/commit\//\/raw\/commit\/}" ;;
    https://code.forgejo.org/*/src/branch/*)  printf '%s\n' "${1/\/src\/branch\//\/raw\/branch\/}" ;;
    https://github.com/*/blob/*)              local u=${1/github.com/raw.githubusercontent.com}; printf '%s\n' "${u/\/blob\//\/}" ;;
    *) return 1 ;;
  esac
}

report() { printf '%-5s %s%s\n' "$1" "$2" "${3:+  -- $3}"; if [[ $1 == FAIL ]]; then fail=$((fail+1)); else ok=$((ok+1)); fi; }

mapfile -t urls < <(grep -ohE 'https://[^ )>"'"'"'`]+' README.md docs/*.md AGENTS.md CHANGELOG.md forgejo-upgrade.sh \
  | sed -e 's/[.,;:]$//' | grep -v '\$' | grep -v '<' | grep -v '\.example\.com' | sort -u)
[[ ${#urls[@]} -gt 0 ]] || { echo "no URLs found: the extraction is broken"; exit 99; }
echo "checking ${#urls[@]} distinct URLs"

for url in "${urls[@]}"; do
  base=${url%%#*}; frag=""; [[ $url == *#* ]] && frag=${url#*#}

  # CVE records: ask MITRE, not the single-page app.
  if [[ $base == https://www.cve.org/CVERecord?id=* ]]; then
    id=${base#*id=}
    f=$(fetch "https://cveawg.mitre.org/api/cve/$id")
    if [[ $(cat "$f.code") == 200 ]] && grep -q 'Forgejo' "$f"; then report OK "$url" "MITRE record names Forgejo"; else report FAIL "$url" "no MITRE record naming Forgejo"; fi
    continue
  fi

  # Line fragments on source hosting: check the raw file at the same pin.
  if [[ -n $frag && $frag =~ ^L([0-9]+)(-L([0-9]+))?$ ]] && raw=$(raw_url "$base"); then
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[3]:-$a}
    f=$(fetch "$raw")
    if [[ $(cat "$f.code") != 200 ]]; then report FAIL "$url" "raw file HTTP $(cat "$f.code")"; continue; fi
    n=$(wc -l < "$f")
    if (( b > n )); then report FAIL "$url" "file has only $n lines"; continue; fi
    path=${base#*/src/commit/*/}; path=${path#*/src/branch/*/}; path=${path#*/blob/*/}
    want=""
    for e in "${EXPECT[@]}"; do [[ ${e%%|*} == "$path#$frag" ]] && want=${e#*|}; done
    if [[ -n $want ]]; then
      if sed -n "${a},${b}p" "$f" | grep -qF -- "$want"; then report OK "$url" "lines $a-$b contain '$want'"; else report FAIL "$url" "lines $a-$b lack '$want'"; fi
    else
      report OK "$url" "lines exist (no phrase registered)"
    fi
    continue
  fi

  # Swagger UI fragments are client-side routes; check the operation exists in the spec.
  if [[ $base == https://code.forgejo.org/api/swagger ]]; then
    f=$(fetch "https://code.forgejo.org/swagger.v1.json")
    op=${frag##*/}
    if grep -q "\"operationId\": *\"$op\"" "$f"; then report OK "$url" "operation $op in spec"; else report FAIL "$url" "operation $op not in spec"; fi
    continue
  fi

  f=$(fetch "$base")
  code=$(cat "$f.code")
  if [[ $code != 200 ]]; then report FAIL "$url" "HTTP $code"; continue; fi
  if [[ -z $frag ]]; then report OK "$url"; continue; fi
  dec=$(printf '%b' "${frag//%/\\x}")
  if grep -qF "id=\"$dec\"" "$f"; then report OK "$url" "id present"; else report FAIL "$url" "no element with id \"$dec\""; fi
done

echo; echo "ok=$ok fail=$fail"
exit "$fail"
