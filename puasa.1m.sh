#!/usr/bin/env bash
set -u

python3 - <<'PY'
import json
import math
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


def fetch_json(url: str, timeout: int = 8):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "PuasaWidget/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def detect_machine_location():
    # Primary: ipinfo
    ipinfo = fetch_json("https://ipinfo.io/json")
    if isinstance(ipinfo, dict):
        loc = (ipinfo.get("loc") or "").split(",")
        if len(loc) == 2:
            try:
                return {
                    "city": ipinfo.get("city") or "Unknown",
                    "region": ipinfo.get("region") or "",
                    "country": (ipinfo.get("country") or "").upper(),
                    "timezone": ipinfo.get("timezone") or "UTC",
                    "lat": float(loc[0]),
                    "lon": float(loc[1]),
                    "source": "ipinfo",
                }
            except Exception:
                pass

    # Secondary: ipwho.is
    ipwho = fetch_json("https://ipwho.is/")
    if isinstance(ipwho, dict) and ipwho.get("success"):
        try:
            return {
                "city": ipwho.get("city") or "Unknown",
                "region": ipwho.get("region") or "",
                "country": (ipwho.get("country_code") or "").upper(),
                "timezone": ((ipwho.get("timezone") or {}).get("id") or "UTC"),
                "lat": float(ipwho.get("latitude")),
                "lon": float(ipwho.get("longitude")),
                "source": "ipwhois",
            }
        except Exception:
            pass

    # Final fallback: timezone only (Malaysia anchor)
    return {
        "city": "Kuala Lumpur",
        "region": "Kuala Lumpur",
        "country": "MY",
        "timezone": "Asia/Kuala_Lumpur",
        "lat": 3.139003,
        "lon": 101.686855,
        "source": "fallback",
    }


def choose_malaysia_zone(lat, lon):
    locations = fetch_json("https://solat.my/api/locations")
    if not isinstance(locations, list) or not locations:
        return None

    best = None
    best_dist = 10**9
    for item in locations:
        try:
            ilat = float(item["latitude"])
            ilon = float(item["longitude"])
            d = haversine_km(lat, lon, ilat, ilon)
            if d < best_dist:
                best_dist = d
                best = item
        except Exception:
            continue

    return best


def parse_hhmm(hms):
    # accepts HH:MM or HH:MM:SS
    return hms[:5]


loc = detect_machine_location()
country = loc["country"]
timezone_name = loc["timezone"]
city_label = loc["city"]
country_label = "Malaysia" if country == "MY" else country
lat = loc["lat"]
lon = loc["lon"]

try:
    tz = ZoneInfo(timezone_name)
except Exception:
    tz = ZoneInfo("UTC")
now = datetime.now(tz)

# Defaults in case all providers fail
times = {
    "imsak": "04:04",
    "fajr": "04:14",
    "maghrib": "17:52",
    "hijri": "-",
}
source_label = "offline fallback"

if country == "MY":
    zone = choose_malaysia_zone(lat, lon)
    if zone and zone.get("code"):
        zone_code = zone["code"]
        city_label = zone.get("location") or city_label
        country_label = "Malaysia"
        daily = fetch_json(f"https://solat.my/api/daily/{zone_code}")
        if isinstance(daily, dict) and daily.get("status") == "OK!":
            pt = (daily.get("prayerTime") or [{}])[0]
            times["imsak"] = parse_hhmm(pt.get("imsak", times["imsak"]))
            times["fajr"] = parse_hhmm(pt.get("fajr", times["fajr"]))
            times["maghrib"] = parse_hhmm(pt.get("maghrib", times["maghrib"]))
            hijri = pt.get("hijri")
            if hijri:
                parts = hijri.split("-")
                if len(parts) == 3:
                    month_names = {
                        "01": "Muharram",
                        "02": "Safar",
                        "03": "Rabi' al-awwal",
                        "04": "Rabi' al-thani",
                        "05": "Jumada al-awwal",
                        "06": "Jumada al-thani",
                        "07": "Rajab",
                        "08": "Sha'ban",
                        "09": "Ramadan",
                        "10": "Shawwal",
                        "11": "Dhu al-Qi'dah",
                        "12": "Dhu al-Hijjah",
                    }
                    y, m, d = parts
                    times["hijri"] = f"{int(d)} {month_names.get(m, m)} {y}"
            source_label = f"live JAKIM ({zone_code})"
else:
    # Non-Malaysia fallback to Aladhan by coordinates
    method_by_country = {"ID": 20, "SG": 11, "BN": 11, "US": 2, "CA": 2}
    method = method_by_country.get(country, 3)
    today_dmy = now.strftime("%d-%m-%Y")
    q = urllib.parse.urlencode(
        {
            "latitude": lat,
            "longitude": lon,
            "method": method,
            "timezonestring": timezone_name,
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
            times["hijri"] = f"{day} {month} {year}"
        source_label = "live Aladhan"


def parse_time(hhmm):
    hh, mm = hhmm.split(":")
    return now.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)


imsak_dt = parse_time(times["imsak"])
maghrib_dt = parse_time(times["maghrib"])

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

greg = now.strftime("%-d %b %Y")
if times["hijri"] == "-":
    date_line = greg
else:
    date_line = f"{greg} / {times['hijri']}"

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
print('Quit SwiftBar | bash="osascript" param1="-e" param2="tell application \\\"SwiftBar\\\" to quit" terminal=false')
PY
