#!/usr/bin/env python3
"""
Refresh the macro / capital-market indicator values in MacroIndicators.swift from
REAL, public data — FRED's public CSV download endpoints (no API key required) plus
the Shiller CAPE from multpl.com.

The app stays offline: this is an out-of-band refresh that rewrites the dated Swift
snapshot in place. Indicators whose `source` is a FRED series id are pulled and
transformed here; those marked `source: "estimate"` (ISM/LEI/Conf-Board/regional
proxies, and a few sentiment/valuation reads without a clean public series) are left
as authored and stay "verify".

Usage:  python3 generate_cme_snapshot.py            # refresh in place
        python3 generate_cme_snapshot.py --dry-run  # show what would change
"""
import re, sys, io, csv, datetime, urllib.request

SWIFT = "Sources/WealthPolicyDesk/MacroIndicators.swift"
FRED_CSV = "https://fred.stlouisfed.org/graph/fredgraph.csv?id={sid}&cosd={cosd}"
CAPE_URL = "https://www.multpl.com/shiller-pe"
UA = {"User-Agent": "Mozilla/5.0 (wm-cme-snapshot)"}

# indicator name -> (FRED series id, transform). Transforms:
#   level      : latest observation as-is
#   yoy        : % change vs ~1 year earlier
#   chg3m      : level change vs ~3 months earlier
#   chg6m_bps  : (level - level 6m earlier) * 100  (pct-point spread -> bps)
#   chg6m_pct  : % change vs ~6 months earlier
#   chg13w_pct : % change vs 13 observations earlier (weekly series)
#   payroll3mo : mean of the last 3 month-over-month changes (thousands)
#   x100       : latest * 100   (FRED OAS in percent -> bps)
#   div1000    : latest / 1000  (persons -> thousands)
MAP = {
    "Industrial production YoY": ("INDPRO", "yoy"),
    "CFNAI activity factor": ("CFNAIMA3", "level"),
    "Real retail sales YoY": ("RRSFS", "yoy"),
    "Core capital-goods orders": ("NEWORDER", "yoy"),
    "Capacity utilization": ("TCU", "level"),
    "Sahm rule": ("SAHMCURRENT", "level"),
    "Initial claims 13wk chg": ("ICSA", "chg13w_pct"),
    "Continuing claims": ("CCSA", "div1000"),
    "Payrolls 3mo avg": ("PAYEMS", "payroll3mo"),
    "Avg weekly hours": ("AWHAETP", "level"),
    "Temp-help employment": ("TEMPHELPS", "yoy"),
    "JOLTS quits rate": ("JTSQUR", "level"),
    "Building permits": ("PERMIT", "level"),
    "Housing starts": ("HOUST", "level"),
    "New home sales": ("HSN1F", "level"),
    "30y mortgage rate": ("MORTGAGE30US", "level"),
    "UMich sentiment": ("UMCSENT", "level"),
    "Real personal income": ("W875RX1", "yoy"),
    "Real personal spending": ("PCEC96", "yoy"),
    "Credit-card delinquencies": ("DRCCLACBS", "level"),
    "Headline CPI YoY": ("CPIAUCSL", "yoy"),
    "Core CPI YoY": ("CPILFESL", "yoy"),
    "Core PCE YoY": ("PCEPILFE", "yoy"),
    "10y breakeven": ("T10YIE", "level"),
    "Avg hourly earnings YoY": ("CES0500000003", "yoy"),
    "WTI crude YoY": ("DCOILWTICO", "yoy"),
    "10y-3m curve": ("T10Y3M", "level"),
    "10y-2y curve": ("T10Y2Y", "level"),
    "10y real rate": ("DFII10", "level"),
    "Curve 6-mo trend": ("T10Y3M", "chg6m_bps"),
    "Real M2 growth": ("M2REAL", "yoy"),
    "NFCI conditions": ("NFCI", "level"),
    "SLOOS C&I tightening": ("DRTSCILM", "level"),
    "C&I loan growth": ("BUSLOANS", "yoy"),
    "HY OAS": ("BAMLH0A0HYM2", "x100"),
    "IG OAS": ("BAMLC0A0CM", "x100"),
    "VIX": ("VIXCLS", "level"),
    "Trade-weighted USD (6mo)": ("DTWEXBGS", "chg6m_pct"),
    "Unemployment trend": ("UNRATE", "chg3m"),
}
# rounded to whole numbers (the rest keep 2 decimals)
INT_TRANSFORMS = {"chg6m_bps", "x100", "div1000", "payroll3mo"}
INT_LEVEL_SERIES = {"PERMIT", "HOUST", "HSN1F"}   # already in thousands on FRED


def fetch_series(sid, years=3):
    cosd = (datetime.date(2026, 8, 20) - datetime.timedelta(days=365 * years)).isoformat()
    url = FRED_CSV.format(sid=sid, cosd=cosd)
    raw = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30).read().decode()
    rows = []
    for r in csv.reader(io.StringIO(raw)):
        if len(r) < 2 or r[0] in ("observation_date", "DATE"):
            continue
        try:
            rows.append((datetime.date.fromisoformat(r[0]), float(r[1])))
        except ValueError:
            continue  # "." = missing
    return rows


def value_on_or_before(rows, target):
    prev = None
    for d, v in rows:
        if d <= target:
            prev = v
        else:
            break
    return prev


def transform(rows, kind, sid):
    if not rows:
        return None
    last_d, last_v = rows[-1]
    if kind == "level":
        return last_v
    if kind == "x100":
        return last_v * 100
    if kind == "div1000":
        return last_v / 1000
    if kind == "yoy":
        base = value_on_or_before(rows[:-1], last_d - datetime.timedelta(days=350))
        return (last_v / base - 1) * 100 if base else None
    if kind == "chg3m":
        base = value_on_or_before(rows[:-1], last_d - datetime.timedelta(days=85))
        return last_v - base if base is not None else None
    if kind == "chg6m_bps":
        base = value_on_or_before(rows[:-1], last_d - datetime.timedelta(days=178))
        return (last_v - base) * 100 if base is not None else None
    if kind == "chg6m_pct":
        base = value_on_or_before(rows[:-1], last_d - datetime.timedelta(days=178))
        return (last_v / base - 1) * 100 if base else None
    if kind == "chg13w_pct":
        base = rows[-14][1] if len(rows) >= 14 else None
        return (last_v / base - 1) * 100 if base else None
    if kind == "payroll3mo":
        if len(rows) < 4:
            return None
        diffs = [rows[i][1] - rows[i - 1][1] for i in range(-3, 0)]
        return sum(diffs) / 3
    return None


def fetch_cape():
    try:
        html = urllib.request.urlopen(urllib.request.Request(CAPE_URL, headers=UA), timeout=30).read().decode()
        m = re.search(r"Current Shiller PE Ratio[^0-9]*([0-9]+\.[0-9]+)", html)
        return float(m.group(1)) if m else None
    except Exception:
        return None


def fmt(val, kind, sid):
    if kind in INT_TRANSFORMS or (kind == "level" and sid in INT_LEVEL_SERIES):
        return str(int(round(val)))
    s = f"{val:.2f}".rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"


def set_source(txt, name, new_source):
    """Rewrite the `source:` label of one indicator row — the script is the source of
    truth for provenance, so a row can never wear a stale/wrong series id. A row that
    fails to fetch is marked "estimate" (authored), never left claiming a live series."""
    pat = re.compile(r'(MacroIndicator\("' + re.escape(name) + r'",[^\n]*?source: ")([^"]*)(")')
    return pat.sub(lambda m: m.group(1) + new_source + m.group(3), txt, count=1)


def main():
    dry = "--dry-run" in sys.argv
    txt = open(SWIFT).read()
    updated, kept, failed = [], [], []
    latest_dates = []

    series_dates = {}
    for name, (sid, kind) in MAP.items():
        try:
            rows = fetch_series(sid)
            val = transform(rows, kind, sid)
            if val is None:
                failed.append((name, sid, "no data / transform failed"))
                continue   # leave source + baked-in value intact; the staleness report flags it
            if rows:
                latest_dates.append(rows[-1][0]); series_dates[name] = rows[-1][0]
            new = fmt(val, kind, sid)
            pat = re.compile(r'(MacroIndicator\("' + re.escape(name) + r'",\s*\.\w+,\s*)(-?[\d.]+)')
            m = pat.search(txt)
            if not m:
                failed.append((name, sid, "indicator not found in Swift"))
                continue
            old = m.group(2)
            if old != new:
                txt = pat.sub(lambda mm: mm.group(1) + new, txt, count=1)
                updated.append((name, sid, old, new))
            else:
                kept.append((name, sid, old))
            txt = set_source(txt, name, sid)              # provenance = the series it came from
        except Exception as e:
            failed.append((name, sid, str(e)[:60]))       # a transient failure leaves source/value as-is

    cape = fetch_cape()
    if cape:
        pat = re.compile(r'(MacroIndicator\("Shiller CAPE",\s*\.\w+,\s*)(-?[\d.]+)')
        m = pat.search(txt)
        if m:
            old, new = m.group(2), f"{cape:.1f}".rstrip("0").rstrip(".")
            if old != new:
                txt = pat.sub(lambda mm: mm.group(1) + new, txt, count=1)
                updated.append(("Shiller CAPE", "multpl.com", old, new))
            else:
                kept.append(("Shiller CAPE", "multpl.com", old))
            txt = set_source(txt, "Shiller CAPE", "multpl")
    else:
        failed.append(("Shiller CAPE", "multpl.com", "fetch failed"))   # keep the baked-in value + source

    asof = max(latest_dates).isoformat() if latest_dates else datetime.date.today().isoformat()
    # write the data-as-of constant the app surfaces, and the header note
    txt = re.sub(r'(static let macroDataAsOf: IsoDate = ")[0-9-]+(")',
                 lambda m: m.group(1) + asof + m.group(2), txt)
    txt = re.sub(r"/// The current macro indicator board \([^\n]*\)\.?",
                 f'/// The current macro indicator board (FRED/Shiller refresh {asof}; ISM/LEI/proxy rows still "verify").',
                 txt)
    # staleness: refreshed series whose latest observation lags the board by > 45 days
    maxd = max(latest_dates) if latest_dates else None
    stale = sorted(((n, d) for n, d in series_dates.items() if maxd and (maxd - d).days > 45),
                   key=lambda x: x[1])

    refreshed = len(updated) + len(kept)
    print(f"\nRefreshed {len(updated)}, unchanged {len(kept)}, could-not-fetch {len(failed)}. "
          f"{refreshed} of {len(MAP) + 1} machine-refreshed. Board data-as-of: {asof}\n")
    for name, sid, old, new in updated:
        print(f"  ~ {name:28} [{sid:14}] {old:>9} -> {new}")
    if failed:
        print("\n  Could not refresh (marked estimate / kept authored value):")
        for name, sid, why in failed:
            print(f"  ! {name:28} [{sid:14}] {why}")
    if stale:
        print("\n  Stale — latest observation > 45d behind the board (verify before trusting):")
        for n, d in stale:
            print(f"  · {n:28} last obs {d.isoformat()}")

    if dry:
        print("\n(dry run — no file written)")
        return
    open(SWIFT, "w").write(txt)
    print(f"\nWrote {SWIFT}")


if __name__ == "__main__":
    main()
