#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
BASE_DIR="/var/lib/boghche/stats"
STATE_DIR="${BASE_DIR}/state"
CURRENT_DIR="${BASE_DIR}/current"
DAILY_DIR="${BASE_DIR}/daily"
MAX_MB="${BOGHCHE_STATS_MAX_MB:-2048}"
TOP_N="${BOGHCHE_TOP_N:-10}"
TODAY="$(date -u +%F)"
NOW="$(date -u +%FT%TZ)"

mkdir -p "$STATE_DIR" "$CURRENT_DIR" "$DAILY_DIR"

lan_regex() {
  if [ -f "$CONFIG" ]; then
    jq -r '([
      "10.11.11.0/30",
      "10.20.30.0/30",
      "192.168.0.0/16",
      "172.16.0.0/16",
      "172.18.0.0/16"
    ] + (.default_lans // []) + (.route_subnets // []) + (.lans // [])) | unique | .[]' "$CONFIG" 2>/dev/null || true
  else
    printf '%s\n' "10.11.11.0/30" "10.20.30.0/30" "192.168.0.0/16" "172.16.0.0/16" "172.18.0.0/16"
  fi | awk '
    function esc(s){gsub(/\./,"\\.",s); return s}
    /\/16$/ {split($0,a,"."); print "^" a[1] "\\." a[2] "\\."; next}
    /\/24$/ {split($0,a,"."); print "^" a[1] "\\." a[2] "\\." a[3] "\\."; next}
    /\/30$/ {split($0,a,"."); print "^" a[1] "\\." a[2] "\\." a[3] "\\.(" a[4] "|" a[4]+1 "|" a[4]+2 "|" a[4]+3 ")$"; next}
    /\/32$/ {sub(/\/32$/,""); print "^" esc($0) "$"; next}
    /^[0-9]+\./ {print "^" esc($0) "$"}
  ' | paste -sd'|' -
}

prune_storage() {
  local size_mb
  size_mb=$(du -sm "$BASE_DIR" 2>/dev/null | awk '{print $1}')
  while [ "${size_mb:-0}" -gt "$MAX_MB" ]; do
    oldest=$(find "$DAILY_DIR" "$CURRENT_DIR" "$STATE_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n1 | cut -d' ' -f2- || true)
    [ -n "${oldest:-}" ] || break
    rm -f "$oldest" || true
    size_mb=$(du -sm "$BASE_DIR" 2>/dev/null | awk '{print $1}')
  done
}

collect_conntrack() {
  command -v conntrack >/dev/null 2>&1 || {
    cat > "${CURRENT_DIR}/top_ips.json" <<EOF
{"updated_at":"${NOW}","source":"conntrack","error":"conntrack command not found","top_ips":[]}
EOF
    return 0
  }

  local regex prev_file new_file delta_file daily_file top_file
  regex=$(lan_regex)
  prev_file="${STATE_DIR}/conntrack.prev"
  new_file="${STATE_DIR}/conntrack.new"
  delta_file="${STATE_DIR}/conntrack.delta"
  daily_file="${DAILY_DIR}/${TODAY}.tsv"
  top_file="${CURRENT_DIR}/top_ips.json"

  conntrack -L -o extended 2>/dev/null | awk -v re="$regex" '
    function field(name,   i,p) {
      for (i=1;i<=NF;i++) if ($i ~ "^" name "=") {split($i,p,"="); return p[2]}
      return ""
    }
    function bytes_sum(   i,p,total) {
      total=0
      for (i=1;i<=NF;i++) if ($i ~ /^bytes=/) {split($i,p,"="); total+=p[2]}
      return total
    }
    {
      proto=$1; src=field("src"); dst=field("dst"); sport=field("sport"); dport=field("dport")
      if (src == "" || dst == "") next
      ip=""
      if (src ~ re) ip=src; else if (dst ~ re) ip=dst; else next
      key=proto "|" src "|" dst "|" sport "|" dport
      print key "\t" ip "\t" bytes_sum()
    }
  ' | sort > "$new_file"

  awk '
    BEGIN {FS=OFS="\t"}
    NR==FNR {prev[$1]=$3; next}
    {
      d=$3 - prev[$1]
      if (d < 0) d=$3
      if (d > 0) print $2,d
    }
  ' "$prev_file" "$new_file" 2>/dev/null > "$delta_file" || cp /dev/null "$delta_file"

  if [ -s "$delta_file" ]; then
    awk 'BEGIN{FS=OFS="\t"} {sum[$1]+=$2} END{for (ip in sum) print ip,sum[ip]}' "$delta_file" >> "$daily_file"
  fi

  cp "$new_file" "$prev_file"

  awk -v updated="$NOW" -v n="$TOP_N" '
    BEGIN {FS=OFS="\t"}
    {sum[$1]+=$2}
    END {
      print "{\"updated_at\":\"" updated "\",\"source\":\"conntrack_delta\",\"top_ips\":["
      for (ip in sum) print sum[ip] "\t" ip | "sort -nr | head -n " n
    }
  ' "$daily_file" > "${STATE_DIR}/top.raw"

  awk '
    BEGIN {first=1}
    /^[0-9]/ {
      bytes=$1; ip=$2
      if (!first) printf ","
      printf "{\"ip\":\"%s\",\"bytes\":%s}", ip, bytes
      first=0
    }
    END {print "]}"}
  ' "${STATE_DIR}/top.raw" >> "${STATE_DIR}/top.raw"

  # Rebuild JSON safely from sorted top rows.
  {
    printf '{"updated_at":"%s","source":"conntrack_delta","top_ips":[' "$NOW"
    awk 'NR==1{next} /^[0-9]/ {if (c++) printf ","; printf "{\"ip\":\"%s\",\"bytes\":%s}", $2, $1}' "${STATE_DIR}/top.raw"
    printf ']}'
  } > "$top_file"
}

show_top() {
  local file="${CURRENT_DIR}/top_ips.json"
  if [ ! -f "$file" ]; then
    collect_conntrack
  fi
  jq -r '.top_ips[]? | "\(.ip)\t\(.bytes)"' "$file" 2>/dev/null | awk '
    function human(x){
      if (x>=1073741824) return sprintf("%.2f GB", x/1073741824)
      if (x>=1048576) return sprintf("%.2f MB", x/1048576)
      if (x>=1024) return sprintf("%.2f KB", x/1024)
      return x " B"
    }
    BEGIN {printf "%-4s %-18s %12s\n", "#", "IP", "Today"}
    {printf "%-4d %-18s %12s\n", NR, $1, human($2)}'
}

case "${1:-collect}" in
  collect)
    collect_conntrack
    prune_storage
    ;;
  top)
    show_top
    ;;
  prune)
    prune_storage
    ;;
  *)
    echo "Usage: $0 {collect|top|prune}"
    exit 1
    ;;
esac
