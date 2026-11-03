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
#
# Webapp: starts of the web app, being loads of the app page at
# <app>.solidcommunity.au, counted from the Caddy apps log (logging
# enabled 20261104). A start is a GET of the page returning 200, or
# 304 when the browser revalidates its cached copy. Every load counts.
#
# Pub: Dart/Flutter packages of our pub.dev publishers. Each run
# records today's downloads_30d, likes and points, and the weekly
# download totals pub.dev reports for the past 52 weeks, dated by the
# week as pub.dev dates it, so history is available from the first run.
#
# GitHub: the non-fork repositories of our GitHub owners named after
# an app or package known from the other sources (plus GH_REPOS). Each
# run records today's stars, forks, watchers, open issues, release
# asset downloads, and 14 day unique visitors and cloners, and the
# daily views and clones GitHub reports for the past 14 days.

CSV="${HOME}/.local/share/podmetrics/podmetrics.csv"

WEB_HOST=solidcommunity.au
WEB_LOGS="/var/log/caddy/installers*.log*"
APP_LOGS="/var/log/caddy/apps*.log*"

# Google Play apps as name=applicationId.

PLAY_APPS=(
    innerpod=com.togaware.innerpod
)

# pub.dev publishers whose packages are collected.

PUB_PUBLISHERS=(
    togaware.com
)

# GitHub owners searched for repositories, and further repositories
# to include beyond those named after a known app or package.

GH_OWNERS=(
    anusii
    gjwgit
)
GH_REPOS=(
    mlhub
    wajig
)

DAYS=7
COLLECT=true
APPS=false
PUB=false
GITHUB=false
REPORT=""

show_help() {
    echo "Usage: $(basename "$0") [options] [app ...]"
    echo ""
    echo "By default the data file is first UPDATED from every source and"
    echo "then summarised:"
    echo ""
    echo "  snap    Snap Store metrics for the last ${DAYS} days (-d), needs snapcraft login."
    echo "  play    Google Play lifetime installs, today's figure."
    echo "  web     Installer downloads from the ${WEB_HOST} access log, via ssh."
    echo "  webapp  Web app starts at <app>.${WEB_HOST}, from its access log, via ssh."
    echo "  pub     pub.dev packages of ${PUB_PUBLISHERS[*]}: today's figures and 52 weeks of downloads."
    echo "  github  Repos of ${GH_OWNERS[*]} named after an app or package: today's figures"
    echo "          and 14 days of traffic, needs gh login."
    echo ""
    echo "With -c nothing is fetched: only the current (cached) data file"
    echo "is summarised, as at its last update."
    echo ""
    echo "With apps (or pub packages) listed only those are updated and"
    echo "summarised, otherwise all."
    echo ""
    echo "Data file: ${CSV}"
    echo ""
    echo "Options:"
    echo "  -c, --cached       Use the current (cached) data file only. No update."
    echo "  -a, --apps         Summary layout of one row per app, sources across columns."
    echo "  -p, --pub          Summary of the pub.dev packages instead of the apps."
    echo "  -g, --github       Summary of the GitHub repositories instead of the apps."
    echo "  -r, --report       One page PDF report of the app and pub.dev metrics,"
    echo "                     written to podmetrics.pdf in the current directory."
    echo "  -d, --days <n>     Days of snap metrics to fetch when updating (default: ${DAYS})."
    echo "  -f, --file <csv>   Data file to update and summarise."
    echo "  -h, --help         Show this help message."
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                  Update all apps from all sources, then summarise."
    echo "  $(basename "$0") -c -a            Per-app summary of the current data file."
    echo "  $(basename "$0") -c innerpod      Summary for innerpod from the current data file."
    echo "  $(basename "$0") -c -p            Summary of the pub.dev packages from the current data file."
    echo "  $(basename "$0") -c -g            Summary of the GitHub repositories from the current data file."
    echo "  $(basename "$0") -c -r            PDF report from the current data file, no update."
    exit 0
}

ONLY=()

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
        -c | --cached | --current)
            COLLECT=false
            shift
            ;;
        -a | --apps)
            APPS=true
            shift
            ;;
        -p | --pub)
            PUB=true
            shift
            ;;
        -g | --github)
            GITHUB=true
            shift
            ;;
        -r | --report)
            REPORT="podmetrics.pdf"
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
            ONLY+=("$1")
            shift
            ;;
    esac
done

# Listed apps as ",a,b," for matching, empty meaning all apps.

ONLY_LIST=""
[ ${#ONLY[@]} -gt 0 ] && ONLY_LIST=",$(IFS=,; echo "${ONLY[*]}"),"

selected() {
    [ -z "${ONLY_LIST}" ] || [[ "${ONLY_LIST}" == *",$1,"* ]]
}

# Filter CSV rows (stdin) to the listed apps.

filter_apps() {
    awk -F, -v only="${ONLY_LIST}" 'only == "" || index(only, "," $3 ",")'
}

# The CSV data rows for the listed apps.

rows() {
    tail -n +2 "${CSV}" | filter_apps
}

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

# Web app starts as CSV rows on stdout, counted per day and app (the
# first label of the host) on the server.

collect_starts() {
    ssh -o BatchMode=yes "${WEB_HOST}" \
        "sudo -n sh -c 'zcat -f ${APP_LOGS}' 2>/dev/null |
         jq -r 'select(.request.method == \"GET\")
                | select(.status == 200 or .status == 304)
                | [(.ts | strflocaltime(\"%F\")), (.request.host | split(\".\")[0])]
                | @tsv' | sort | uniq -c" |
        awk '{ printf "%s,webapp,%s,starts,%d\n", $2, $3, $1 }'
}

# The pub.dev packages of a publisher, one per line, over all pages.

pub_packages() {
    local url="https://pub.dev/api/search?q=publisher:$1" page
    while [ -n "${url}" ] && [ "${url}" != "null" ]; do
        page=$(curl -s "${url}")
        echo "${page}" | jq -r '.packages[].package'
        url=$(echo "${page}" | jq -r '.next')
    done
}

# pub.dev metrics for one package as CSV rows on stdout.

collect_pub() {
    curl -s "https://pub.dev/api/packages/$1/metrics" |
        jq -r --arg p "$1" --arg today "$(date +%F)" '
          (.score | [$today, "pub", $p, "downloads_30d", .downloadCount30Days],
                    [$today, "pub", $p, "likes", .likeCount],
                    [$today, "pub", $p, "points", .grantedPoints]),
          (.scorecard.weeklyVersionDownloads // empty
           | (.newestDate | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t
           | .totalWeeklyDownloads | to_entries[]
           | [($t - .key * 7 * 86400 | strftime("%F")), "pub", $p, "weekly_downloads", .value])
          | select(.[4] != null) | @csv' 2>/dev/null | tr -d '"'
}

# The GitHub repositories to collect as owner/name, one per line: the
# non-fork repos of GH_OWNERS named after a package in the CSV (other
# than from github itself) or listed in GH_REPOS.

github_repos() {
    local names
    names=$({ printf '%s\n' "${GH_REPOS[@]}"
              [ -f "${CSV}" ] && tail -n +2 "${CSV}" | awk -F, '$2 != "github" {print $3}'
            } | sort -u)
    for owner in "${GH_OWNERS[@]}"; do
        gh repo list "${owner}" --limit 1000 --json name,isFork \
           --jq ".[] | select(.isFork | not) | \"${owner}/\" + .name" 2>/dev/null
    done | awk -F/ -v names="$(echo ${names})" '
      BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
      ($2 in want) && !seen[$2]++'
}

# GitHub metrics for one owner/name repository as CSV rows on stdout,
# recorded against the repository name.

collect_github() {
    local repo=$1 name=${1#*/} today
    today=$(date +%F)
    gh api "repos/${repo}" --jq \
       "[\"stars\", .stargazers_count], [\"forks\", .forks_count],
        [\"watchers\", .subscribers_count], [\"issues\", .open_issues_count]
        | \"${today},github,${name},\" + .[0] + \",\" + (.[1] | tostring)" 2>/dev/null
    gh api --paginate "repos/${repo}/releases?per_page=100" \
       --jq '.[].assets[].download_count' 2>/dev/null |
        awk -v p="${today},github,${name}" '{ s += $1 } END { printf "%s,release_downloads,%d\n", p, s }'
    for kind in views clones; do
        gh api "repos/${repo}/traffic/${kind}" --jq \
           "\"${today},github,${name},$([ ${kind} = views ] && echo visitors || echo cloners)_14d,\" + (.uniques | tostring),
            (.${kind}[] | (.timestamp[0:10]) + \",github,${name},${kind},\" + (.count | tostring))" 2>/dev/null
    done
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

# Latest installed base (snap) per package, the total (play installs,
# web downloads, webapp starts) and the activity over the last 7 and
# 30 days (snap new devices, web downloads, webapp starts). A "-"
# marks a metric the source does not provide.

summarise() {
    if [ ! -f "${CSV}" ]; then
        echo "No metrics file ${CSV} found." >&2
        exit 1
    fi
    echo "Metrics from ${CSV} ($(rows | wc -l) rows)"
    echo ""
    rows | awk -F, -v now="$(date +%F)" '
      function days(d,   cmd, s) {
        cmd = "date -d " d " +%s"; cmd | getline s; close(cmd); return s
      }
      BEGIN { t = days(now) }
      $2 == "pub" || $2 == "github" { next }
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
        if ($2 == "web" || $2 == "webapp") {
          if ($1 >= last[k]) last[k] = $1
          dl[k] += $5
        }
        if ($4 == "new" || $2 == "web" || $2 == "webapp") {
          age = (t - days($1)) / 86400
          if (age <= 7)  n7[k]  += $5
          if (age <= 30) n30[k] += $5
        }
      }
      END {
        for (k in pkgs) {
          split(k, a, FS)
          if (k in ilast)      printf "%s,%s,%s,%d,-,%d,%d\n", a[1], a[2], last[k], inst[k], n7[k], n30[k]
          else if (a[1] == "web" || a[1] == "webapp") printf "%s,%s,%s,-,%d,%d,%d\n", a[1], a[2], last[k], dl[k], n7[k], n30[k]
          else                 printf "%s,%s,%s,-,%d,-,-\n",   a[1], a[2], last[k], dl[k]
        }
      }' | sort -t, -k1,1r -k4,4nr -k5,5nr |
        awk -F, '
          BEGIN {
            f = "%-6s %-12s %-10s %10s %10s %8s %8s\n"
            printf f, "Source", "Package", "As At", "Installed", "Total", "Last 7d", "Last 30d"
            printf f, "------", "-------", "-----", "---------", "-----", "-------", "--------"
          }
          {
            printf f, $1, $2, $3, $4, $5, $6, $7
            ti += $4; td += $5; t7 += $6; t30 += $7
          }
          END {
            printf f, "", "TOTAL", "", ti, td, t7, t30
            print ""
            print "snap: installed devices, new devices. play: lifetime installs."
            print "web: installer downloads. webapp: web app starts."
          }'
}

# One row per app with each source's figures across the columns:
# snap installed base (latest) and new devices, play installs
# (latest), web downloads per platform, and web app starts, all over
# the whole CSV. Activity totals snap new, play installs, web
# downloads and web app starts; installed base is a level, not
# activity, so is excluded.

summarise_apps() {
    if [ ! -f "${CSV}" ]; then
        echo "No metrics file ${CSV} found." >&2
        exit 1
    fi
    echo "Metrics by app from ${CSV} since $(rows | cut -d, -f1 | sort | head -1)"
    echo ""
    rows | awk -F, '
      $2 == "pub" || $2 == "github" { next }
      {
        app[$3] = 1
        if ($2 == "snap" && $4 == "installed_base" && $1 >= sd[$3]) { sd[$3] = $1; v[$3, "si"] = $5 }
        else if ($2 == "snap" && $4 == "new")                         v[$3, "sn"] += $5
        else if ($2 == "play" && $4 == "installs" && $1 >= pd[$3])    { pd[$3] = $1; v[$3, "pi"] = $5 }
        else if ($2 == "web")                                         v[$3, "w" $4] += $5
        else if ($2 == "webapp" && $4 == "starts")                    v[$3, "as"] += $5
        else next
        has[$3, ($2 == "snap" && $4 == "installed_base") ? "si" : ($2 == "snap") ? "sn" : ($2 == "play") ? "pi" : ($2 == "webapp") ? "as" : "w" $4] = 1
      }
      END {
        n = split("si sn pi wandroid wlinux wmacos wwindows as", c, " ")
        for (a in app) {
          line = a; act = 0
          for (i = 1; i <= n; i++) {
            line = line "," (((a, c[i]) in has) ? v[a, c[i]] : "-")
            if (c[i] != "si") act += v[a, c[i]]
          }
          print line "," act
        }
      }' | sort -t, -k10,10nr -k1,1 |
        awk -F, '
          BEGIN {
            f = "%-12s %9s %8s %8s %8s %8s %8s %8s %8s %9s\n"
            printf f, "", "Snap", "Snap", "Play", "Web", "Web", "Web", "Web", "Web App", ""
            printf f, "App", "Installed", "New", "Installs", "Android", "Linux", "macOS", "Windows", "Starts", "Activity"
            printf f, "---", "---------", "----", "--------", "-------", "-----", "-----", "-------", "------", "--------"
          }
          {
            printf f, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
            for (i = 2; i <= 10; i++) t[i] += $i
          }
          END {
            printf f, "TOTAL", t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10]
          }'
}

# One row per pub.dev package: latest points, likes and 30 day
# downloads, the latest week's downloads, and the total over the 52
# weeks to that week.

summarise_pub() {
    if [ ! -f "${CSV}" ]; then
        echo "No metrics file ${CSV} found." >&2
        exit 1
    fi
    echo "pub.dev packages from ${CSV}"
    echo ""
    rows | awk -F, '
      $2 != "pub" { next }
      $4 == "weekly_downloads" { w[$3, $1] = $5; if ($1 > wd[$3]) wd[$3] = $1; next }
      { pkg[$3] = 1; if ($1 >= d[$3, $4]) { d[$3, $4] = $1; v[$3, $4] = $5 } }
      END {
        for (p in pkg) {
          yr = 0; cut = prior(wd[p])
          for (k in w) {
            split(k, a, SUBSEP)
            if (a[1] == p && a[2] > cut) yr += w[k]
          }
          printf "%s,%s,%d,%d,%d,%d,%d\n", p, d[p, "points"], v[p, "points"], v[p, "likes"],
                 v[p, "downloads_30d"], w[p, wd[p]], yr
        }
      }
      function prior(date,   cmd, s) {
        cmd = "date -d \"" date " -364 days\" +%F"; cmd | getline s; close(cmd); return s
      }' | sort -t, -k5,5nr -k1,1 |
        awk -F, '
          BEGIN {
            f = "%-24s %-10s %6s %6s %10s %9s %10s\n"
            printf f, "Package", "As At", "Points", "Likes", "Downloads", "Last Week", "Downloads"
            printf f, "", "", "", "", "30 Days", "", "52 Weeks"
            printf f, "-------", "-----", "------", "-----", "---------", "---------", "---------"
          }
          {
            printf f, $1, $2, $3, $4, $5, $6, $7
            for (i = 4; i <= 7; i++) t[i] += $i
          }
          END {
            printf f, "TOTAL", "", "", t[4], t[5], t[6], t[7]
          }'
}

# One row per GitHub repository: the latest stars, forks, watchers,
# open issues and release downloads, and the views and clones over
# the 14 days to the latest traffic date, with their unique visitors
# and cloners as GitHub reports them.

summarise_github() {
    if [ ! -f "${CSV}" ]; then
        echo "No metrics file ${CSV} found." >&2
        exit 1
    fi
    echo "GitHub repositories from ${CSV}"
    echo ""
    rows | awk -F, '
      function prior(date,   cmd, s) {
        cmd = "date -d \"" date " -13 days\" +%F"; cmd | getline s; close(cmd); return s
      }
      $2 != "github" { next }
      $4 == "views" || $4 == "clones" { t[$3, $4, $1] = $5; if ($1 > td[$3]) td[$3] = $1; next }
      { repo[$3] = 1; if ($1 >= d[$3, $4]) { d[$3, $4] = $1; v[$3, $4] = $5 } }
      END {
        for (r in repo) {
          views = clones = 0
          if (r in td) {
            cut = prior(td[r])
            for (k in t) {
              split(k, a, SUBSEP)
              if (a[1] == r && a[3] >= cut) {
                if (a[2] == "views") views += t[k]; else clones += t[k]
              }
            }
          }
          printf "%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", r, d[r, "stars"],
                 v[r, "stars"], v[r, "forks"], v[r, "watchers"], v[r, "issues"],
                 v[r, "release_downloads"], views, v[r, "visitors_14d"], clones, v[r, "cloners_14d"]
        }
      }' | sort -t, -k3,3nr -k1,1 |
        awk -F, '
          BEGIN {
            f = "%-24s %-10s %5s %5s %8s %6s %9s %6s %8s %6s %8s\n"
            printf f, "", "", "", "", "", "Open", "Release", "Views", "Visitors", "Clones", "Cloners"
            printf f, "Repository", "As At", "Stars", "Forks", "Watchers", "Issues", "Downloads", "14d", "14d", "14d", "14d"
            printf f, "----------", "-----", "-----", "-----", "--------", "------", "---------", "-----", "--------", "------", "-------"
          }
          {
            printf f, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
            for (i = 3; i <= 11; i++) t[i] += $i
          }
          END {
            printf f, "TOTAL", "", t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11]
          }'
}

# One page A4 landscape PDF report of the app and pub.dev package
# metrics from the current data file, drawn with R and ggplot2.

report() {
    if [ ! -f "${CSV}" ]; then
        echo "No metrics file ${CSV} found." >&2
        exit 1
    fi
    if ! command -v Rscript > /dev/null; then
        echo "Error: Rscript (with ggplot2, dplyr, patchwork, ggrepel) is required for -r." >&2
        exit 1
    fi
    local tmp
    tmp=$(mktemp --suffix=.csv)
    { echo "date,source,package,metric,value"; rows; } > "${tmp}"
    Rscript - "${tmp}" "${REPORT}" "${CSV}" <<'EOF'
suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(patchwork); library(ggrepel); library(scales)
})
args <- commandArgs(TRUE)
d <- read.csv(args[1], colClasses = c("Date", rep("character", 3), "numeric"))

# Light (print) palette: surface, ink, and the categorical slots in
# their fixed, CVD validated order.

surf <- "#fcfcfb"; ink <- "#0b0b0b"; ink2 <- "#52514e"; rule <- "#e6e5e1"
cat8 <- c("#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948")

today <- max(d$date)
from  <- today - 29
num   <- function(x) format(round(x), big.mark = ",", trim = TRUE)

theme_pm <- theme_minimal(base_size = 9) +
  theme(plot.background  = element_rect(fill = surf, colour = NA),
        panel.grid.minor = element_blank(),
        panel.grid.major = element_line(colour = rule, linewidth = 0.3),
        axis.text        = element_text(colour = ink2),
        axis.title       = element_text(colour = ink2),
        legend.text      = element_text(colour = ink2),
        legend.position  = "top", legend.justification = "left",
        legend.title     = element_blank(),
        plot.title       = element_text(colour = ink, face = "bold", size = 11),
        plot.subtitle    = element_text(colour = ink2, size = 8),
        plot.caption     = element_text(colour = ink2, size = 7, hjust = 0))

empty <- function(title, msg) {
  ggplot() + annotate("text", 0, 0, label = msg, colour = ink2, size = 3.2) +
    theme_void() + labs(title = title) +
    theme(plot.title = element_text(colour = ink, face = "bold", size = 11),
          plot.background = element_rect(fill = surf, colour = NA))
}

apps <- filter(d, source != "pub")
pub  <- filter(d, source == "pub")

# Panel 1: activity over the last 30 days by app and source. Play is
# the change in lifetime installs across the snapshots in the window.

play <- apps %>% filter(source == "play", metric == "installs", date >= from) %>%
  group_by(package) %>% arrange(date) %>%
  summarise(value = last(value) - first(value), .groups = "drop") %>%
  mutate(kind = "Play installs")
act <- bind_rows(
  apps %>% filter(source == "snap", metric == "new", date >= from) %>% mutate(kind = "Snap new devices"),
  play,
  apps %>% filter(source == "web", date >= from) %>% mutate(kind = "Web downloads"),
  apps %>% filter(source == "webapp", metric == "starts", date >= from) %>% mutate(kind = "Web app starts")) %>%
  group_by(package, kind) %>% summarise(value = sum(value), .groups = "drop") %>%
  filter(value > 0)
kinds <- c("Snap new devices", "Play installs", "Web downloads", "Web app starts")

if (nrow(act) == 0) {
  p1 <- empty("Activity, last 30 days", "No activity in the last 30 days")
} else {
  tot <- act %>% group_by(package) %>% summarise(total = sum(value)) %>%
    arrange(desc(total)) %>% head(15)
  act <- filter(act, package %in% tot$package) %>%
    mutate(package = factor(package, levels = rev(tot$package)),
           kind = factor(kind, levels = rev(kinds)))
  p1 <- ggplot(act, aes(value, package)) +
    geom_col(aes(fill = kind), width = 0.7, colour = surf, linewidth = 0.4) +
    geom_text(data = tot, aes(total, package, label = num(total)),
              hjust = -0.15, size = 2.6, colour = ink) +
    scale_fill_manual(values = setNames(cat8[1:4], kinds), breaks = intersect(kinds, act$kind)) +
    scale_x_continuous(labels = label_comma(), expand = expansion(mult = c(0, 0.12))) +
    labs(title = "Activity, last 30 days",
         subtitle = paste0(format(from, "%d %b"), " to ", format(today, "%d %b %Y"), ", top apps by total"),
         x = NULL, y = NULL,
         caption = "Web downloads logged from 3 Nov 2026, web app starts from 4 Nov 2026.") +
    theme_pm + theme(panel.grid.major.y = element_blank())
}

# Panel 2: snap installed base over time for the top six snaps.

inst <- apps %>% filter(source == "snap", metric == "installed_base")
if (nrow(inst) == 0) {
  p2 <- empty("Snap installed base", "No snap data")
} else {
  top <- inst %>% group_by(package) %>% filter(date == max(date)) %>%
    ungroup() %>% arrange(desc(value)) %>% head(6)
  inst <- filter(inst, package %in% top$package)
  cols <- setNames(cat8[seq_along(sort(top$package))], sort(top$package))
  ends <- inst %>% group_by(package) %>% filter(date == max(date))
  p2 <- ggplot(inst, aes(date, value, colour = package)) +
    geom_line(linewidth = 0.7) +
    geom_text_repel(data = ends, aes(label = paste0(package, " ", num(value))),
                    hjust = 0, nudge_x = 2, direction = "y", size = 2.6,
                    colour = ink, segment.colour = rule, min.segment.length = 0) +
    scale_colour_manual(values = cols) +
    scale_x_date(date_labels = "%d %b", expand = expansion(mult = c(0.02, 0.22))) +
    scale_y_continuous(labels = label_comma(), limits = c(0, NA)) +
    labs(title = "Snap installed base",
         subtitle = "Active devices per day, summed over channels, top six snaps",
         x = NULL, y = NULL) +
    theme_pm
  if (nrow(top) == 1) p2 <- p2 + theme(legend.position = "none")
}

# Panel 3: total weekly pub.dev downloads over the past 52 weeks.

wk <- pub %>% filter(metric == "weekly_downloads") %>%
  group_by(date) %>% summarise(value = sum(value), .groups = "drop") %>%
  filter(date > max(date) - 364)
if (nrow(wk) == 0) {
  p3 <- empty("pub.dev weekly downloads", "No pub.dev data")
} else {
  last_wk <- filter(wk, date == max(date))
  p3 <- ggplot(wk, aes(date, value)) +
    geom_area(fill = cat8[1], alpha = 0.12) +
    geom_line(colour = cat8[1], linewidth = 0.7) +
    geom_point(data = last_wk, colour = cat8[1], size = 2) +
    geom_text(data = last_wk, aes(label = num(value)), vjust = -1, size = 2.6, colour = ink) +
    scale_x_date(date_labels = "%b %y") +
    scale_y_continuous(labels = label_comma(), limits = c(0, NA), expand = expansion(mult = c(0, 0.15))) +
    labs(title = "pub.dev weekly downloads",
         subtitle = paste0("All packages, 52 weeks, ", num(sum(wk$value)), " in total"),
         x = NULL, y = NULL) +
    theme_pm
}

# Panel 4: 30 day downloads per pub.dev package.

d30 <- pub %>% filter(metric == "downloads_30d") %>% group_by(package) %>%
  filter(date == max(date)) %>% ungroup()
if (nrow(d30) == 0) {
  p4 <- empty("pub.dev downloads, last 30 days", "No pub.dev data")
} else {
  d30 <- mutate(d30, package = reorder(package, value))
  p4 <- ggplot(d30, aes(value, package)) +
    geom_col(fill = cat8[1], width = 0.7) +
    geom_text(aes(label = num(value)), hjust = -0.15, size = 2.6, colour = ink) +
    scale_x_continuous(labels = label_comma(), expand = expansion(mult = c(0, 0.12))) +
    labs(title = "pub.dev downloads, last 30 days",
         subtitle = paste0("Per package, as at ", format(max(d30$date), "%d %b %Y")),
         x = NULL, y = NULL) +
    theme_pm + theme(panel.grid.major.y = element_blank())
}

# Headline figures for the page subtitle.

latest_inst <- inst %>% group_by(package) %>% filter(date == max(date)) %>% pull(value)
head_line <- paste0(
  "As at ", format(today, "%d %B %Y"),
  "   |   Snap installed devices ", num(sum(latest_inst)),
  "   |   App activity, 30 days ", num(sum(act$value)),
  "   |   pub.dev downloads, 30 days ", num(sum(d30$value)))

page <- (p1 | p2) / (p3 | p4) +
  plot_annotation(title = "Package Metrics", subtitle = head_line,
                  caption = paste("Generated by podmetrics.sh from", args[3]),
                  theme = theme(plot.title = element_text(colour = ink, face = "bold", size = 16),
                                plot.subtitle = element_text(colour = ink2, size = 9),
                                plot.caption = element_text(colour = ink2, size = 7),
                                plot.background = element_rect(fill = surf, colour = NA)))

ggsave(args[2], page, width = 11.69, height = 8.27, units = "in", device = cairo_pdf, bg = surf)
EOF
    local status=$?
    rm -f "${tmp}"
    if [ ${status} -eq 0 ]; then
        echo "Report written to $(realpath "${REPORT}")"
    else
        echo "Error: report generation failed." >&2
        exit 1
    fi
}

if ${COLLECT}; then
    SNAPS=()
    if ! command -v snapcraft > /dev/null || ! command -v jq > /dev/null; then
        echo "Warning: snapcraft and jq are required for snap metrics, skipping." >&2
    elif ! snapcraft whoami > /dev/null 2>&1; then
        echo "Warning: not logged in (run: snapcraft login), skipping snap metrics." >&2
    else
        mapfile -t SNAPS < <(snapcraft names 2>/dev/null | awk 'NR>1 {print $1}')
    fi
    {
        for snap in "${SNAPS[@]}"; do
            selected "${snap}" || continue
            echo "Collecting snap metrics for ${snap}..." >&2
            collect_snap "${snap}"
        done
        for app in "${PLAY_APPS[@]}"; do
            selected "${app%%=*}" || continue
            echo "Collecting play metrics for ${app%%=*}..." >&2
            collect_play "${app%%=*}" "${app#*=}"
        done
        echo "Collecting web downloads from ${WEB_HOST}..." >&2
        collect_web
        echo "Collecting web app starts from ${WEB_HOST}..." >&2
        collect_starts
        for publisher in "${PUB_PUBLISHERS[@]}"; do
            for pkg in $(pub_packages "${publisher}"); do
                selected "${pkg}" || continue
                echo "Collecting pub metrics for ${pkg}..." >&2
                collect_pub "${pkg}"
            done
        done
    } | filter_apps | merge_csv

    # GitHub last, as its repositories are those named after the apps
    # and packages now in the CSV.

    if ! command -v gh > /dev/null || ! gh auth status > /dev/null 2>&1; then
        echo "Warning: gh is required and logged in (run: gh auth login), skipping github." >&2
    else
        github_repos | while read -r repo; do
            selected "${repo#*/}" || continue
            echo "Collecting github metrics for ${repo}..." >&2
            collect_github "${repo}"
        done | filter_apps | merge_csv
    fi
    echo "" >&2
fi

if [ -f "${CSV}" ] && [ -z "$(rows)" ]; then
    echo "No metrics found for: ${ONLY[*]}" >&2
    exit 1
fi

if [ -n "${REPORT}" ]; then
    report
elif ${PUB}; then
    summarise_pub
elif ${GITHUB}; then
    summarise_github
elif ${APPS}; then
    summarise_apps
else
    summarise
fi
