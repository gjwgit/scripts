#!/bin/bash
#
# Graham Williams 20261103
#
# Collect download/usage metrics for our packages into a CSV file and
# summarise the latest figures. Each row of the CSV is:
#
#   date,source,package,metric,value
#
# Rows are keyed on (date,source,package,metric) so re-running simply
# refreshes existing rows and adds new ones. Further sources (github
# releases, pypi, cran, ...) can be added as additional collect_*
# functions writing rows in the same format.
#
# Snap: the store does not publish raw download counts. We record
# installed_base (active devices summed over channels), and the daily
# new and lost device counts. Store metrics lag by a day or two so we
# fetch a window of recent days and keep whatever has data.
#
# Play: we record installs, the lifetime install count embedded in the
# public store page alongside the displayed bracket (e.g. "10+"). This
# is undocumented and may break if Google changes the page. It is a
# snapshot so is recorded against today's date.
#
# Web: installer downloads from solidcommunity.au, counted from the
# Caddy access log (logging enabled 20261103, so nothing earlier). A
# download is a GET returning 200, or a 206 range starting at byte 0,
# counted once per client IP per file per day. Each run recounts the
# whole log (kept 365 days) so earlier days are simply refreshed.
# Metrics are per platform: android, linux, macos, windows.

CSV="${HOME}/.local/share/podmetrics/podmetrics.csv"

WEB_HOST=solidcommunity.au
WEB_LOGS="/var/log/caddy/installers*.log*"

# Google Play apps as name=applicationId.

PLAY_APPS=(
    innerpod=com.togaware.innerpod
)
DAYS=7
COLLECT=true
APPS=false

show_help() {
    echo "Usage: $0 [options] [snap ...]"
    echo ""
    echo "Collect metrics into ${CSV} and summarise. With no snaps listed"
    echo "all snaps registered to the snapcraft login are collected."
    echo ""
    echo "Options:"
    echo "  -f, --file <csv>   CSV file to create/update (default: ${CSV})."
    echo "  -d, --days <n>     Number of recent days to fetch (default: ${DAYS})."
    echo "  -s, --summary      Only summarise the existing CSV, no collection."
    echo "  -a, --apps         Summarise one row per app, sources across columns."
    echo "  -h, --help         Show this help message."
    exit 0
}

SNAPS=()

while [[ "$1" != "" ]]; do
    case $1 in
        -f | --file)
            shift
            CSV="$1"
            shift
            ;;
        -d | --days)
            shift
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                DAYS=$1
                shift
            else
                echo "Error: --days requires a number." >&2
                exit 1
            fi
            ;;
        -s | --summary)
            COLLECT=false
            shift
            ;;
        -a | --apps)
            APPS=true
            shift
            ;;
        -h | --help)
            show_help
            ;;
        -*)
            echo "Error: unknown option $1" >&2
            exit 1
            ;;
        *)
            SNAPS+=("$1")
            shift
            ;;
    esac
done

# Snap metrics for one snap as CSV rows on stdout.

collect_snap() {
    local snap=$1
    local start end
    start=$(date -d "-${DAYS} days" +%F)
    end=$(date -d "yesterday" +%F)

    # Installed base: sum the channel series for each day.

    snapcraft metrics "${snap}" --name installed_base_by_channel \
              --start "${start}" --end "${end}" --format=json 2>/dev/null |
        jq -r --arg p "${snap}" '
          select(.status == "OK") | . as $m
          | range(0; $m.buckets | length) as $i
          | [$m.series[].values[$i] | select(. != null)] as $v
          | select($v | length > 0)
          | [$m.buckets[$i], "snap", $p, "installed_base", ($v | add)]
          | @csv' | tr -d '"'

    # Daily device change: new and lost devices.

    snapcraft metrics "${snap}" --name daily_device_change \
              --start "${start}" --end "${end}" --format=json 2>/dev/null |
        jq -r --arg p "${snap}" '
          select(.status == "OK") | . as $m
          | range(0; $m.buckets | length) as $i
          | $m.series[] | select(.name == "new" or .name == "lost")
          | select(.values[$i] != null)
          | [$m.buckets[$i], "snap", $p, .name, .values[$i]]
          | @csv' | tr -d '"'
}

# Play installs for one app as a CSV row on stdout. The page embeds
# ["10+",10,22,"10+"] being display, minimum and actual installs.

collect_play() {
    local name=$1 id=$2 installs
    installs=$(curl -sL "https://play.google.com/store/apps/details?id=${id}&hl=en&gl=US" |
                   grep -oE '\["[0-9,]+\+",[0-9]+,[0-9]+,"[0-9,]+\+"\]' |
                   head -1 | cut -d, -f3)
    if [[ "${installs}" =~ ^[0-9]+$ ]]; then
        echo "$(date +%F),play,${name},installs,${installs}"
    else
        echo "Warning: no play installs found for ${id}." >&2
    fi
}

# Web installer downloads as CSV rows on stdout. The log is filtered
# on the server to unique (date, ip, file) then classified here.

collect_web() {
    ssh -o BatchMode=yes "${WEB_HOST}" \
        "sudo -n sh -c 'zcat -f ${WEB_LOGS}' 2>/dev/null |
         jq -r 'select(.request.method == \"GET\")
                | select(.status == 200 or (.status == 206 and
                    ((.request.headers.Range[0] // \"\") | startswith(\"bytes=0-\"))))
                | [(.ts | strflocaltime(\"%F\")), .request.client_ip,
                   (.request.uri | split(\"?\")[0] | ltrimstr(\"/installers/\"))]
                | @tsv' | sort -u" |
        awk -F'\t' '
          {
            f = $3
            if (f ~ /\.(apk|aab)$/)                                  p = "android"
            else if (f ~ /(\.deb|\.snap|\.flatpak|-linux\.zip|\.tar\.gz)$/) p = "linux"
            else if (f ~ /(macos.*\.(zip|dmg)|\.dmg)$/)              p = "macos"
            else if (f ~ /(windows.*\.(zip|exe)|\.exe)$/)            p = "windows"
            else next
            pkg = f; sub(/[-_.].*/, "", pkg)
            n[$1 "," pkg "," p]++
          }
          END {
            for (k in n) {
              split(k, a, ",")
              printf "%s,web,%s,%s,%d\n", a[1], a[2], a[3], n[k]
            }
          }'
}

# Merge new rows (stdin) into the CSV, new rows replacing old ones
# with the same key, sorted by date then source, package, metric.

merge_csv() {
    local tmp
    mkdir -p "$(dirname "${CSV}")"
    tmp=$(mktemp)
    {
        cat -
        [ -f "${CSV}" ] && tail -n +2 "${CSV}"
    } | awk -F, '!seen[$1 FS $2 FS $3 FS $4]++' |
        sort -t, -k1,1 -k2,2 -k3,3 -k4,4 > "${tmp}"
    {
        echo "date,source,package,metric,value"
        cat "${tmp}"
    } > "${CSV}"
    rm -f "${tmp}"
}

# Latest installed base (snap) and downloads (play, web) per package
# plus new devices (snap) or downloads (web) over the last 7 and 30
# days. A "-" marks a metric the source does not provide.

summarise() {
    if [ ! -f "${CSV}" ]; then
        echo "No metrics file ${CSV} found." >&2
        exit 1
    fi
    echo "Metrics from ${CSV} ($(($(wc -l < "${CSV}") - 1)) rows)"
    echo ""
    tail -n +2 "${CSV}" | awk -F, -v now="$(date +%F)" '
      function days(d,   cmd, s) {
        cmd = "date -d " d " +%s"; cmd | getline s; close(cmd); return s
      }
      BEGIN { t = days(now) }
      {
        k = $2 FS $3
        pkgs[k] = 1
        if (($4 == "installed_base" || $4 == "installs") && $1 >= last[k]) {
          last[k] = $1
        }
        if ($4 == "installed_base" && $1 >= ilast[k]) {
          ilast[k] = $1; inst[k] = $5
        }
        if ($4 == "installs" && $1 >= dlast[k]) {
          dlast[k] = $1; dl[k] = $5
        }
        if ($2 == "web") {
          if ($1 >= last[k]) last[k] = $1
          dl[k] += $5
        }
        if ($4 == "new" || $2 == "web") {
          age = (t - days($1)) / 86400
          if (age <= 7)  n7[k]  += $5
          if (age <= 30) n30[k] += $5
        }
      }
      END {
        for (k in pkgs) {
          split(k, a, FS)
          if (k in ilast)      printf "%s,%s,%s,%d,-,%d,%d\n", a[1], a[2], last[k], inst[k], n7[k], n30[k]
          else if (a[1] == "web") printf "%s,%s,%s,-,%d,%d,%d\n", a[1], a[2], last[k], dl[k], n7[k], n30[k]
          else                 printf "%s,%s,%s,-,%d,-,-\n",   a[1], a[2], last[k], dl[k]
        }
      }' | sort -t, -k1,1r -k4,4nr -k5,5nr |
        awk -F, '
          BEGIN {
            f = "%-6s %-12s %-10s %10s %10s %8s %8s\n"
            printf f, "Source", "Package", "As At", "Installed", "Downloads", "New 7d", "New 30d"
            printf f, "------", "-------", "-----", "---------", "---------", "------", "-------"
          }
          {
            printf f, $1, $2, $3, $4, $5, $6, $7
            ti += $4; td += $5; t7 += $6; t30 += $7
          }
          END {
            printf f, "", "TOTAL", "", ti, td, t7, t30
          }'
}

# One row per app with each source's figures across the columns:
# snap installed base (latest) and new devices, play installs
# (latest), and web downloads per platform, all over the whole CSV.
# Activity totals the acquisitions (snap new, play installs, web
# downloads); installed base is a level, not activity, so is excluded.

summarise_apps() {
    if [ ! -f "${CSV}" ]; then
        echo "No metrics file ${CSV} found." >&2
        exit 1
    fi
    echo "Metrics by app from ${CSV} since $(tail -n +2 "${CSV}" | cut -d, -f1 | sort | head -1)"
    echo ""
    tail -n +2 "${CSV}" | awk -F, '
      {
        app[$3] = 1
        if ($2 == "snap" && $4 == "installed_base" && $1 >= sd[$3]) { sd[$3] = $1; v[$3, "si"] = $5 }
        else if ($2 == "snap" && $4 == "new")                         v[$3, "sn"] += $5
        else if ($2 == "play" && $4 == "installs" && $1 >= pd[$3])    { pd[$3] = $1; v[$3, "pi"] = $5 }
        else if ($2 == "web")                                         v[$3, "w" $4] += $5
        else next
        has[$3, ($2 == "snap" && $4 == "installed_base") ? "si" : ($2 == "snap") ? "sn" : ($2 == "play") ? "pi" : "w" $4] = 1
      }
      END {
        n = split("si sn pi wandroid wlinux wmacos wwindows", c, " ")
        for (a in app) {
          line = a; act = 0
          for (i = 1; i <= n; i++) {
            line = line "," (((a, c[i]) in has) ? v[a, c[i]] : "-")
            if (c[i] != "si") act += v[a, c[i]]
          }
          print line "," act
        }
      }' | sort -t, -k9,9nr -k1,1 |
        awk -F, '
          BEGIN {
            f = "%-12s %9s %8s %8s %8s %8s %8s %8s %9s\n"
            printf f, "", "Snap", "Snap", "Play", "Web", "Web", "Web", "Web", ""
            printf f, "App", "Installed", "New", "Installs", "Android", "Linux", "macOS", "Windows", "Activity"
            printf f, "---", "---------", "----", "--------", "-------", "-----", "-----", "-------", "--------"
          }
          {
            printf f, $1, $2, $3, $4, $5, $6, $7, $8, $9
            for (i = 2; i <= 9; i++) t[i] += $i
          }
          END {
            printf f, "TOTAL", t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9]
          }'
}

if ${COLLECT}; then
    if ! command -v snapcraft > /dev/null || ! command -v jq > /dev/null; then
        echo "Warning: snapcraft and jq are required for snap metrics, skipping." >&2
        SNAPS=()
    elif ! snapcraft whoami > /dev/null 2>&1; then
        echo "Warning: not logged in (run: snapcraft login), skipping snap metrics." >&2
        SNAPS=()
    elif [ ${#SNAPS[@]} -eq 0 ]; then
        mapfile -t SNAPS < <(snapcraft names 2>/dev/null | awk 'NR>1 {print $1}')
    fi
    {
        for snap in "${SNAPS[@]}"; do
            echo "Collecting snap metrics for ${snap}..." >&2
            collect_snap "${snap}"
        done
        for app in "${PLAY_APPS[@]}"; do
            echo "Collecting play metrics for ${app%%=*}..." >&2
            collect_play "${app%%=*}" "${app#*=}"
        done
        echo "Collecting web downloads from ${WEB_HOST}..." >&2
        collect_web
    } | merge_csv
    echo "" >&2
fi

if ${APPS}; then
    summarise_apps
else
    summarise
fi
