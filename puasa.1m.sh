#!/usr/bin/env bash
set -u

# Optional: saved selected zone code from widget menu (e.g. PRK02, WLY01).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.puasa_widget_config"
FORCE_WAKTU_ZONE=""

if [[ "${1:-}" == "--set-zone" && -n "${2:-}" ]]; then
  printf 'FORCE_WAKTU_ZONE="%s"\n' "$2" > "$CONFIG_FILE"
  exit 0
fi

if [[ "${1:-}" == "--clear-zone" ]]; then
  rm -f "$CONFIG_FILE"
  exit 0
fi

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

export FORCE_WAKTU_ZONE
export SCRIPT_PATH="$0"

python3 - <<'PY'
import html as ihtml
import json
import os
import re
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


def fetch_text(url: str, timeout: int = 10):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "PuasaWidget/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="ignore")
    except Exception:
        return ""


def fetch_json(url: str, timeout: int = 10):
    txt = fetch_text(url, timeout)
    if not txt:
        return None
    try:
        return json.loads(txt)
    except Exception:
        return None


def detect_machine_location():
    ipinfo = fetch_json("https://ipinfo.io/json")
    if isinstance(ipinfo, dict):
        loc = (ipinfo.get("loc") or "").split(",")
        if len(loc) == 2:
            try:
                return {
                    "city": (ipinfo.get("city") or "").strip(),
                    "region": (ipinfo.get("region") or "").strip(),
                    "country": (ipinfo.get("country") or "").upper(),
                    "timezone": ipinfo.get("timezone") or "UTC",
                    "lat": float(loc[0]),
                    "lon": float(loc[1]),
                    "source": "ipinfo",
                }
            except Exception:
                pass

    ipwho = fetch_json("https://ipwho.is/")
    if isinstance(ipwho, dict) and ipwho.get("success"):
        try:
            return {
                "city": (ipwho.get("city") or "").strip(),
                "region": (ipwho.get("region") or "").strip(),
                "country": (ipwho.get("country_code") or "").upper(),
                "timezone": ((ipwho.get("timezone") or {}).get("id") or "UTC"),
                "lat": float(ipwho.get("latitude")),
                "lon": float(ipwho.get("longitude")),
                "source": "ipwhois",
            }
        except Exception:
            pass

    return {
        "city": "Kuala Lumpur",
        "region": "Kuala Lumpur",
        "country": "MY",
        "timezone": "Asia/Kuala_Lumpur",
        "lat": 3.139003,
        "lon": 101.686855,
        "source": "fallback",
    }


def parse_waktu_zone_options(index_html: str):
    options = []
    for m in re.finditer(r"<option\s+value='(https://www\.waktusolat\.my/[^']+)'\s*>\s*([^<]+)</option>", index_html, re.I):
        url = m.group(1).strip()
        text = ihtml.unescape(m.group(2)).strip()
        c = re.match(r"([A-Z]{3}\d{2})\s*-\s*(.+)", text)
        if not c:
            continue
        code = c.group(1).upper()
        desc = c.group(2).strip()
        path = urllib.parse.urlparse(url).path.lower()
        options.append({"code": code, "url": url, "desc": desc, "path": path})
    return options


def choose_zone(options, loc, forced_code):
    if forced_code:
        forced = forced_code.strip().upper()
        if forced == "WLY01":
            return {
                "code": "WLY01",
                "url": "https://www.waktusolat.my/",
                "desc": "Kuala Lumpur dan Putrajaya",
                "path": "/",
            }
        for o in options:
            if o["code"] == forced:
                return o

    city = (loc.get("city") or "").lower().strip()
    region = (loc.get("region") or "").lower().strip()

    # waktusolat.my homepage is WLY01 by default, and WLY01 may not appear in dropdown options.
    if city in ("kuala lumpur", "putrajaya") or region in ("kuala lumpur", "putrajaya"):
        return {
            "code": "WLY01",
            "url": "https://www.waktusolat.my/",
            "desc": "Kuala Lumpur dan Putrajaya",
            "path": "/",
        }

    state_to_path = {
        "kuala lumpur": "/kuala-lumpur-putrajaya/",
        "putrajaya": "/kuala-lumpur-putrajaya/",
        "labuan": "/labuan/",
        "perak": "/perak/",
        "selangor": "/selangor/",
        "johor": "/johor/",
        "kedah": "/kedah/",
        "kelantan": "/kelantan/",
        "melaka": "/melaka/",
        "negeri sembilan": "/negeri-sembilan/",
        "pahang": "/pahang/",
        "perlis": "/perlis/",
        "pulau pinang": "/pulau-pinang/",
        "sabah": "/sabah/",
        "sarawak": "/sarawak/",
        "terengganu": "/terengganu/",
    }

    best = None
    best_score = -1
    for o in options:
        desc_l = o["desc"].lower()
        path = o["path"]
        score = 0

        if city and city in desc_l:
            score += 100
        if region and region in desc_l:
            score += 60

        if region in state_to_path and state_to_path[region] in path:
            score += 40

        # Common Klang Valley aliases
        if city in ("kuala lumpur", "putrajaya") and o["code"] == "WLY01":
            score += 30

        if score > best_score:
            best_score = score
            best = o

    # If nothing matched strongly, default to WLY01 then first entry
    if best_score <= 0:
        for o in options:
            if o["code"] == "WLY01":
                return o

    return best or (options[0] if options else None)


def parse_waktu_zone_page(zone_html: str):
    def find_time(label):
        p = re.compile(rf"<h4[^>]*>\s*{label}\s*</h4>\s*<span>\s*(\d{{2}}:\d{{2}})\s*</span>", re.I)
        m = p.search(zone_html)
        return m.group(1) if m else None

    imsak = find_time("Imsak")
    subuh = find_time("Subuh")
    maghrib = find_time("Maghrib")

    loc_match = re.search(r"<h3>\s*Waktu\s+Solat\s+([^<]+)</h3>", zone_html, re.I)
    loc_label = ihtml.unescape(loc_match.group(1)).strip() if loc_match else None

    date_match = re.search(r"<h5>\s*([^<]+)</h5>", zone_html, re.I)
    date_label = ihtml.unescape(date_match.group(1)).strip() if date_match else None

    return {
        "imsak": imsak,
        "fajr": subuh,
        "maghrib": maghrib,
        "location": loc_label,
        "date_line": date_label,
    }


def parse_time(now, hhmm):
    hh, mm = hhmm.split(":")
    return now.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)


loc = detect_machine_location()
country = loc["country"]
force_zone = os.getenv("FORCE_WAKTU_ZONE", "").strip().upper()
script_path = os.getenv("SCRIPT_PATH", "./puasa.1m.sh")


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

try:
    tz = ZoneInfo(loc.get("timezone") or "UTC")
except Exception:
    tz = ZoneInfo("UTC")
now = datetime.now(tz)

city_label = loc.get("city") or "Unknown"
country_label = "Malaysia" if country == "MY" else country
source_label = "offline fallback"
opts = []
chosen = None

times = {
    "imsak": "04:04",
    "fajr": "04:14",
    "maghrib": "17:52",
    "hijri": "-",
}
date_line = now.strftime("%-d %b %Y")

if country == "MY":
    index_html = fetch_text("https://www.waktusolat.my/")
    opts = parse_waktu_zone_options(index_html)
    opts_map = {o["code"]: o for o in opts}
    if "WLY01" not in opts_map:
        opts.append(
            {
                "code": "WLY01",
                "url": "https://www.waktusolat.my/",
                "desc": "Kuala Lumpur dan Putrajaya",
                "path": "/",
            }
        )
    chosen = choose_zone(opts, loc, force_zone)

    if chosen:
        zone_html = fetch_text(chosen["url"])
        parsed = parse_waktu_zone_page(zone_html)

        if parsed["imsak"] and parsed["fajr"] and parsed["maghrib"]:
            times["imsak"] = parsed["imsak"]
            times["fajr"] = parsed["fajr"]
            times["maghrib"] = parsed["maghrib"]
            source_label = f"live waktusolat.my ({chosen['code']})"

        if parsed.get("location"):
            city_label = parsed["location"]
            country_label = "Malaysia"

        if parsed.get("date_line"):
            # Example: 20 February 2026 , 02 Ramadan 1447H
            date_line = parsed["date_line"].replace(" , ", " / ").strip()

# Non-MY fallback from Aladhan
if source_label == "offline fallback":
    method_by_country = {"ID": 20, "SG": 11, "BN": 11, "US": 2, "CA": 2}
    method = method_by_country.get(country, 3)
    today_dmy = now.strftime("%d-%m-%Y")
    q = urllib.parse.urlencode(
        {
            "latitude": loc["lat"],
            "longitude": loc["lon"],
            "method": method,
            "timezonestring": loc.get("timezone") or "UTC",
        }
    )
    api = fetch_json(f"https://api.aladhan.com/v1/timings/{today_dmy}?{q}")
    if isinstance(api, dict) and api.get("code") == 200:
        data = api.get("data", {})
        t = data.get("timings", {})
        h = data.get("date", {}).get("hijri", {})
        times["imsak"] = (t.get("Imsak") or times["imsak"]).split(" ")[0][:5]
        times["fajr"] = (t.get("Fajr") or times["fajr"]).split(" ")[0][:5]
        times["maghrib"] = (t.get("Maghrib") or times["maghrib"]).split(" ")[0][:5]
        day = h.get("day")
        month = (h.get("month") or {}).get("en")
        year = h.get("year")
        if day and month and year:
            date_line = f"{now.strftime('%-d %b %Y')} / {day} {month} {year}"
        source_label = "live Aladhan"

imsak_dt = parse_time(now, times["imsak"])
maghrib_dt = parse_time(now, times["maghrib"])

if now < imsak_dt:
    state = "Belum Mulai Puasa"
    target = imsak_dt
    suffix = "menuju imsak"
elif now < maghrib_dt:
    state = "Sedang Berpuasa"
    target = maghrib_dt
    suffix = "lagi"
else:
    state = "Sudah Berbuka"
    target = imsak_dt + timedelta(days=1)
    suffix = "menuju imsak"

remain = max(0, int((target - now).total_seconds()))
hours = remain // 3600
minutes = (remain % 3600) // 60

print(f"☪ B:{times['maghrib']}")
print("---")
print("🌙 Puasa | size=15")
print("---")
print(f"📍 {city_label}, {country_label}")
print(f"🗓 {date_line}")
print("---")
print(f"🌘 Imsak: {times['imsak']}")
print(f"🌅 Sahur (Subuh): {times['fajr']}")
print(f"🌇 Berbuka (Maghrib): {times['maghrib']}")
print("---")
print(f"🟢 {state}   {hours}j {minutes}m {suffix}")
print("---")
print(f"Refresh ({source_label}, {loc['source']} loc) | refresh=true")
if country == "MY" and opts:
    script_esc = esc(script_path)
    auto_mark = " ✅" if not force_zone else ""
    print(f"Change Location{auto_mark}")
    print(
        f"--Auto (machine location){auto_mark} | bash=\"{script_esc}\" param1=\"--clear-zone\" "
        "refresh=true terminal=false"
    )
    seen = set()
    for o in sorted(opts, key=lambda x: x["code"]):
        code = o["code"]
        if code in seen:
            continue
        seen.add(code)
        mark = " ✅" if force_zone == code else ""
        print(
            f"--{code} - {o['desc']}{mark} | bash=\"{script_esc}\" param1=\"--set-zone\" "
            f"param2=\"{code}\" refresh=true terminal=false"
        )
print('Quit SwiftBar | bash="osascript" param1="-e" param2="tell application \\\"SwiftBar\\\" to quit" terminal=false')
PY
