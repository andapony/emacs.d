#!/bin/sh
# Fetch one iCloud calendar the way rjd-icloud will, and save every raw
# response, to check that iCloud expands recurring events correctly
# (ADR-0002) and to record test fixtures.
#
# Usage: test/icloud-probe.sh APPLE-ID CALENDAR-NAME [OUTDIR]
#
# The app-specific password is read from the `machine caldav.icloud.com'
# line of ~/.authinfo, or asked for.  Responses go to OUTDIR, by default
# ~/tmp/icloud-probe -- outside this public repository, since they hold
# real event data and account IDs.  Sanitise before copying any into
# test/.
#
# Never issues anything but PROPFIND and REPORT.

set -eu

[ $# -ge 2 ] || { echo "usage: $0 APPLE-ID CALENDAR-NAME [OUTDIR]" >&2; exit 2; }
user=$1
calendar=$2
out=${3:-$HOME/tmp/icloud-probe}
mkdir -p "$out"

pass=$(awk '$1 == "machine" && $2 == "caldav.icloud.com" {
              for (i = 3; i < NF; i++) if ($i == "password") print $(i + 1) }' \
           "$HOME/.authinfo" 2>/dev/null | head -n 1)
if [ -z "$pass" ]; then
  printf 'App-specific password: ' >&2
  stty -echo; read -r pass; stty echo; echo >&2
fi

# dav METHOD URL DEPTH BODY OUTFILE
dav() {
  curl -sS --fail-with-body -X "$1" -u "$user:$pass" \
       -H "Depth: $3" -H 'Content-Type: application/xml; charset=utf-8' \
       --data "$4" -o "$5" "$2"
}

# href FILE XPATH -- the first href under XPATH, by local name
href() {
  xmllint --xpath "string(($2//*[local-name()='href'])[1])" "$1"
}

absolute() {
  case $2 in http*) echo "$2" ;; *) echo "$1$2" ;; esac
}

dav PROPFIND https://caldav.icloud.com/ 0 \
  '<d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>' \
  "$out/1-principal.xml"
principal=$(href "$out/1-principal.xml" "//*[local-name()='current-user-principal']")
echo "principal: $principal"

dav PROPFIND "$(absolute https://caldav.icloud.com "$principal")" 0 \
  '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>' \
  "$out/2-home-set.xml"
home=$(absolute https://caldav.icloud.com \
         "$(href "$out/2-home-set.xml" "//*[local-name()='calendar-home-set']")")
echo "home set: $home"

dav PROPFIND "$home" 1 \
  '<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>' \
  "$out/3-calendars.xml"
echo "calendars:"
xmllint --xpath "//*[local-name()='displayname']/text()" "$out/3-calendars.xml" \
  | sed 's/^/  /'; echo

path=$(xmllint --xpath "string(//*[local-name()='response'][.//*[local-name()='displayname']='$calendar']/*[local-name()='href'])" \
         "$out/3-calendars.xml")
[ -n "$path" ] || { echo "no calendar named '$calendar'" >&2; exit 1; }
url=$(absolute "${home%%/[0-9]*}" "$path")
echo "calendar: $url"

start=$(date -u -v-30d +%Y%m%dT000000Z 2>/dev/null || date -u -d '-30 days' +%Y%m%dT000000Z)
end=$(date -u -v+365d +%Y%m%dT000000Z 2>/dev/null || date -u -d '+365 days' +%Y%m%dT000000Z)

dav REPORT "$url" 1 "<c:calendar-query xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">
  <d:prop><c:calendar-data><c:expand start=\"$start\" end=\"$end\"/></c:calendar-data></d:prop>
  <c:filter><c:comp-filter name=\"VCALENDAR\"><c:comp-filter name=\"VEVENT\">
    <c:time-range start=\"$start\" end=\"$end\"/>
  </c:comp-filter></c:comp-filter></c:filter>
</c:calendar-query>" "$out/4-expanded.xml"

echo "expanded instances (DTSTART / RECURRENCE-ID / SUMMARY):"
grep -E '^(DTSTART|RECURRENCE-ID|SUMMARY|RRULE|EXDATE)' "$out/4-expanded.xml" \
  | sed 's/^/  /'
echo "responses saved in $out"
