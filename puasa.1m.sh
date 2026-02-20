#!/usr/bin/env bash
set -u

# Optional: saved selected zone code from widget menu (e.g. PRK02, WLY01).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.puasa_widget_config"
FORCE_WAKTU_ZONE=""
COUNTDOWN_MODE="solah"
MENUBAR_MODE="remaining"

save_config() {
  cat > "$CONFIG_FILE" <<EOF
FORCE_WAKTU_ZONE="${FORCE_WAKTU_ZONE}"
COUNTDOWN_MODE="${COUNTDOWN_MODE}"
MENUBAR_MODE="${MENUBAR_MODE}"
EOF
}

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

if [[ "${1:-}" == "--set-zone" && -n "${2:-}" ]]; then
  FORCE_WAKTU_ZONE="$2"
  save_config
  exit 0
fi

if [[ "${1:-}" == "--clear-zone" ]]; then
  FORCE_WAKTU_ZONE=""
  save_config
  exit 0
fi

if [[ "${1:-}" == "--set-mode" && -n "${2:-}" ]]; then
  if [[ "$2" == "solah" || "$2" == "puasa" ]]; then
    COUNTDOWN_MODE="$2"
    save_config
  fi
  exit 0
fi

if [[ "${1:-}" == "--set-menubar" && -n "${2:-}" ]]; then
  if [[ "$2" == "berbuka" || "$2" == "remaining" || "$2" == "progress" ]]; then
    MENUBAR_MODE="$2"
    save_config
  fi
  exit 0
fi

export FORCE_WAKTU_ZONE
export COUNTDOWN_MODE
export MENUBAR_MODE
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
    syuruk = find_time("Syuruk")
    zohor = find_time("Zohor") or find_time("Jumaat")
    asar = find_time("Asar")
    maghrib = find_time("Maghrib")
    isyak = find_time("Isyak")

    loc_match = re.search(r"<h3>\s*Waktu\s+Solat\s+([^<]+)</h3>", zone_html, re.I)
    loc_label = ihtml.unescape(loc_match.group(1)).strip() if loc_match else None

    date_match = re.search(r"<h5>\s*([^<]+)</h5>", zone_html, re.I)
    date_label = ihtml.unescape(date_match.group(1)).strip() if date_match else None

    return {
        "imsak": imsak,
        "fajr": subuh,
        "syuruk": syuruk,
        "dhuhr": zohor,
        "asr": asar,
        "maghrib": maghrib,
        "isha": isyak,
        "location": loc_label,
        "date_line": date_label,
    }


def parse_time(now, hhmm):
    hh, mm = hhmm.split(":")
    return now.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)


loc = detect_machine_location()
country = loc["country"]
force_zone = os.getenv("FORCE_WAKTU_ZONE", "").strip().upper()
countdown_mode = os.getenv("COUNTDOWN_MODE", "solah").strip().lower()
menubar_mode = os.getenv("MENUBAR_MODE", "remaining").strip().lower()
script_path = os.getenv("SCRIPT_PATH", "./puasa.1m.sh")


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def fmt_remaining(seconds):
    seconds = max(0, int(seconds))
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    return f"{hours}j {minutes}m"


def make_bar(percent, width=10):
    p = max(0.0, min(100.0, float(percent)))
    filled = int(round((p / 100.0) * width))
    return "[" + ("█" * filled) + ("░" * (width - filled)) + f"] {int(round(p))}%"


def make_mini_bar(percent, width=6):
    p = max(0.0, min(100.0, float(percent)))
    filled = int(round((p / 100.0) * width))
    return ("▰" * filled) + ("▱" * (width - filled))

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
    "syuruk": "05:30",
    "dhuhr": "12:00",
    "asr": "15:30",
    "maghrib": "17:52",
    "isha": "19:00",
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
            times["syuruk"] = parsed.get("syuruk") or times["syuruk"]
            times["dhuhr"] = parsed.get("dhuhr") or times["dhuhr"]
            times["asr"] = parsed.get("asr") or times["asr"]
            times["maghrib"] = parsed["maghrib"]
            times["isha"] = parsed.get("isha") or times["isha"]
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
        times["syuruk"] = (t.get("Sunrise") or times["syuruk"]).split(" ")[0][:5]
        times["dhuhr"] = (t.get("Dhuhr") or times["dhuhr"]).split(" ")[0][:5]
        times["asr"] = (t.get("Asr") or times["asr"]).split(" ")[0][:5]
        times["maghrib"] = (t.get("Maghrib") or times["maghrib"]).split(" ")[0][:5]
        times["isha"] = (t.get("Isha") or times["isha"]).split(" ")[0][:5]
        day = h.get("day")
        month = (h.get("month") or {}).get("en")
        year = h.get("year")
        if day and month and year:
            date_line = f"{now.strftime('%-d %b %Y')} / {day} {month} {year}"
        source_label = "live Aladhan"

imsak_dt = parse_time(now, times["imsak"])
fajr_dt = parse_time(now, times["fajr"])
syuruk_dt = parse_time(now, times["syuruk"])
dhuhr_dt = parse_time(now, times["dhuhr"])
asr_dt = parse_time(now, times["asr"])
maghrib_dt = parse_time(now, times["maghrib"])
isha_dt = parse_time(now, times["isha"])

schedule = [
    ("Subuh", fajr_dt),
    ("Syuruk", syuruk_dt),
    ("Zohor", dhuhr_dt),
    ("Asar", asr_dt),
    ("Maghrib", maghrib_dt),
    ("Isyak", isha_dt),
]
extended = schedule + [("Subuh", fajr_dt + timedelta(days=1))]
prev_name, prev_time = ("Isyak", isha_dt - timedelta(days=1))
next_name, next_time = extended[0]
for name, t in extended:
    if now < t:
        next_name, next_time = name, t
        break
    prev_name, prev_time = name, t
remain_next_solah = max(0, int((next_time - now).total_seconds()))
next_span = max(1.0, (next_time - prev_time).total_seconds())
next_elapsed = max(0.0, min(next_span, (now - prev_time).total_seconds()))
next_solah_percent = (next_elapsed / next_span) * 100.0

if countdown_mode not in ("solah", "puasa"):
    countdown_mode = "solah"
if menubar_mode not in ("berbuka", "remaining", "progress"):
    menubar_mode = "remaining"

if countdown_mode == "puasa":
    if now < imsak_dt:
        state = "Belum Mulai Puasa"
        target = imsak_dt
        suffix = "menuju imsak"
        window_start = imsak_dt - timedelta(hours=12)
        window_end = imsak_dt
    elif now < maghrib_dt:
        state = "Sedang Berpuasa"
        target = maghrib_dt
        suffix = "lagi"
        window_start = imsak_dt
        window_end = maghrib_dt
    else:
        state = "Sudah Berbuka"
        target = imsak_dt + timedelta(days=1)
        suffix = "menuju imsak"
        window_start = maghrib_dt
        window_end = imsak_dt + timedelta(days=1)

    remain = max(0, int((target - now).total_seconds()))
    span = max(1.0, (window_end - window_start).total_seconds())
    elapsed = max(0.0, min(span, (now - window_start).total_seconds()))
    progress_line = f"Puasa Progress {make_bar((elapsed / span) * 100.0)}"
    countdown_line = f"🟢 {state}   {fmt_remaining(remain)} {suffix}"
else:
    remain = remain_next_solah
    span = max(1.0, (next_time - prev_time).total_seconds())
    elapsed = max(0.0, min(span, (now - prev_time).total_seconds()))
    progress_line = f"Solah Progress {make_bar((elapsed / span) * 100.0)}"
    countdown_line = f"🟢 Menuju {next_name}   {fmt_remaining(remain)} lagi"

if menubar_mode == "berbuka":
    menubar_text = f"☪ B:{times['maghrib']}"
elif menubar_mode == "progress":
    menubar_text = f"☪ {next_name} {make_mini_bar(next_solah_percent)}"
else:
    menubar_text = f"☪ {next_name} {fmt_remaining(remain_next_solah)}"
print(menubar_text)
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
print(countdown_line)
print(progress_line)
print("---")
print(f"Refresh ({source_label}, {loc['source']} loc) | refresh=true")
script_esc = esc(script_path)
menu_berbuka_mark = " ✅" if menubar_mode == "berbuka" else ""
menu_remaining_mark = " ✅" if menubar_mode == "remaining" else ""
menu_progress_mark = " ✅" if menubar_mode == "progress" else ""
print("Menu Bar Display")
print(
    f"--Berbuka Time{menu_berbuka_mark} | bash=\"{script_esc}\" param1=\"--set-menubar\" "
    "param2=\"berbuka\" refresh=true terminal=false"
)
print(
    f"--Remaining Waktu Solah{menu_remaining_mark} | bash=\"{script_esc}\" param1=\"--set-menubar\" "
    "param2=\"remaining\" refresh=true terminal=false"
)
print(
    f"--Progress Bar (test){menu_progress_mark} | bash=\"{script_esc}\" param1=\"--set-menubar\" "
    "param2=\"progress\" refresh=true terminal=false"
)
mode_puasa_mark = " ✅" if countdown_mode == "puasa" else ""
mode_solah_mark = " ✅" if countdown_mode == "solah" else ""
print("Progress Mode")
print(
    f"--Next Solah{mode_solah_mark} | bash=\"{script_esc}\" param1=\"--set-mode\" "
    "param2=\"solah\" refresh=true terminal=false"
)
print(
    f"--Puasa{mode_puasa_mark} | bash=\"{script_esc}\" param1=\"--set-mode\" "
    "param2=\"puasa\" refresh=true terminal=false"
)
if country == "MY" and opts:
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
