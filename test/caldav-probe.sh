#!/bin/sh
# Fetch one CalDAV calendar the way rjd-caldav does, and save every raw
# response, to check that the server expands recurring events correctly
# (ADR-0002, ADR-0003) and to record test fixtures.
#
# Usage: test/caldav-probe.sh USER CALENDAR-NAME [OUTDIR]
#
# The server is iCloud's unless CALDAV_SERVER names another, as the URL
# where discovery starts -- Fastmail's, say:
# CALDAV_SERVER=https://caldav.fastmail.com/dav/.  The password is read
# from the ~/.authinfo line whose machine is that URL's host
# (caldav.icloud.com for iCloud), or that host with :443 as url.el
# files it, and whose login is USER, as rjd-caldav looks it up --
# never another login's line for the same host, such as another
# Fastmail address's -- or asked for.  Responses go to OUTDIR, by
# default ~/tmp/caldav-probe -- outside this public repository, since they hold
# real event data and account IDs.  Sanitise before copying any into
# test/fixtures/caldav/.
#
# Needs curl and xmllint.  Never issues anything but PROPFIND and REPORT.

set -eu

[ $# -ge 2 ] || { echo "usage: $0 USER CALENDAR-NAME [OUTDIR]" >&2; exit 2; }
user=$1
calendar=$2
out=${3:-$HOME/tmp/caldav-probe}
server=${CALDAV_SERVER:-https://caldav.icloud.com/}
host=$(echo "$server" | sed -E 's|^https?://([^/]*).*|\1|')
origin=https://$host
mkdir -p "$out"

pass=$(awk -v host="$host" -v user="$user" '{
              machine = login = password = ""
              for (i = 1; i < NF; i += 2) {
                if ($i == "machine") machine = $(i + 1)
                else if ($i == "login") login = $(i + 1)
                else if ($i == "password") password = $(i + 1)
              }
              if ((machine == host || machine == host ":443") \
                  && login == user && password != "") print password
            }' "$HOME/.authinfo" 2>/dev/null | head -n 1)
if [ -z "$pass" ]; then
  printf 'Password for %s at %s: ' "$user" "$host" >&2
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

dav PROPFIND "$server" 0 \
  '<d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>' \
  "$out/1-principal.xml"
principal=$(href "$out/1-principal.xml" "//*[local-name()='current-user-principal']")
echo "principal: $principal"

dav PROPFIND "$(absolute "$origin" "$principal")" 0 \
  '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>' \
  "$out/2-home-set.xml"
home=$(absolute "$origin" \
         "$(href "$out/2-home-set.xml" "//*[local-name()='calendar-home-set']")")
echo "home set: $home"

dav PROPFIND "$home" 1 \
  '<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>' \
  "$out/3-calendars.xml"
# Each name by its string value, so a CDATA section (Fastmail's) comes
# out as the plain name rather than wrapped in <![CDATA[...]]>.
echo "calendars:"
names=$(xmllint --xpath "count(//*[local-name()='displayname'])" "$out/3-calendars.xml")
i=1
while [ "$i" -le "$names" ]; do
  echo "  $(xmllint --xpath "string((//*[local-name()='displayname'])[$i])" \
                    "$out/3-calendars.xml")"
  i=$((i + 1))
done

path=$(xmllint --xpath "string(//*[local-name()='response'][.//*[local-name()='displayname']='$calendar']/*[local-name()='href'])" \
         "$out/3-calendars.xml")
[ -n "$path" ] || { echo "no calendar named '$calendar'" >&2; exit 1; }
url=$(absolute "$(echo "$home" | sed -E 's|^(https?://[^/]*).*|\1|')" "$path")
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
