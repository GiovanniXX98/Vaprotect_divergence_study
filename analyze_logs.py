import re
import os
import glob
from datetime import datetime
from collections import defaultdict

def find_latest_log():
    logs = glob.glob("*923.log") + glob.glob("*.log")
    if logs:
        # prefer 20260923.log if present
        for l in logs:
            if "923.log" in l:
                return l
        return logs[0]
    return "20260923.log"

log_file = find_latest_log()
print(f"Lettura file di log: {log_file}")

# Rilevamento codifica (UTF-16 LE per MT5 o UTF-8)
encoding = "utf-16-le"
try:
    with open(log_file, "r", encoding="utf-16-le") as f:
        f.read(1024)
except Exception:
    encoding = "utf-8"

exit_pat = re.compile(r"(\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})\s+(EXIT_\w+|DEBUG_EXIT_TRADE)\s*\|\s*PnL:\s*([-\d\.]+)(?:\s*\|\s*Z:\s*([-\d\.]+))?(?:\s*\|\s*Ore:\s*([-\d\.]+))?")
start_pat = re.compile(r"testing of .* started with inputs:")
final_balance_pat = re.compile(r"final balance\s+([-\d\.]+)\s+(\w+)")

runs = []
current_run = None

with open(log_file, "r", encoding=encoding, errors="ignore") as f:
    for line in f:
        if start_pat.search(line):
            current_run = {
                "header": line.strip(),
                "episodes": [],
                "raw_exits": [],
                "final_balance": None,
                "currency": "EUR"
            }
            runs.append(current_run)
            continue
        
        fb_match = final_balance_pat.search(line)
        if fb_match and current_run:
            current_run["final_balance"] = float(fb_match.group(1))
            current_run["currency"] = fb_match.group(2)

        m = exit_pat.search(line)
        if m and current_run:
            dt_str = m.group(1)
            motif = m.group(2)
            pnl = float(m.group(3))
            z = float(m.group(4)) if m.group(4) else 0.0
            ore = float(m.group(5)) if m.group(5) else 0.0
            dt = datetime.strptime(dt_str, "%Y.%m.%d %H:%M:%S")

            current_run["raw_exits"].append({"motif": motif, "pnl": pnl, "z": z, "ore": ore})

            # Raggruppamento episodi di uscita (evita conteggi multipli su tentativi a mercato chiuso)
            eps = current_run["episodes"]
            if not eps or (dt - eps[-1]["last_dt"]).total_seconds() > 120 or eps[-1]["motif"] != motif:
                eps.append({
                    "start_dt": dt,
                    "last_dt": dt,
                    "motif": motif,
                    "first_pnl": pnl,
                    "first_ore": ore,
                    "first_z": z,
                    "repeats": 1
                })
            else:
                eps[-1]["last_dt"] = dt
                eps[-1]["repeats"] += 1

if not runs:
    print("Nessun backtest trovato nel log.")
    exit()

print(f"Totale esecuzioni/backtest trovati nel file: {len(runs)}\n")

for idx, r in enumerate(runs):
    print(f"{'='*60}")
    print(f"ANALISI BACKTEST #{idx+1}")
    print(f"{'='*60}")
    if r["final_balance"]:
        print(f"Bilancio Finale MT5: {r['final_balance']:.2f} {r['currency']}")
    print(f"Log uscite grezze (inclusi retry/mercato chiuso): {len(r['raw_exits'])}")
    print(f"Trade effettivi eseguiti (deduplicati): {len(r['episodes'])}\n")

    stats = defaultdict(lambda: {"count": 0, "pnl": 0.0, "wins": 0, "losses": 0, "ores": []})
    tot_pnl = 0.0
    gross_profit = 0.0
    gross_loss = 0.0

    for ep in r["episodes"]:
        m = ep["motif"]
        p = ep["first_pnl"]
        stats[m]["count"] += 1
        stats[m]["pnl"] += p
        tot_pnl += p
        if ep["first_ore"] < 10000:  # filtra ore corrotte da reset a 0
            stats[m]["ores"].append(ep["first_ore"])

        if p > 0:
            stats[m]["wins"] += 1
            gross_profit += p
        elif p < 0:
            stats[m]["losses"] += 1
            gross_loss += abs(p)

    total_episodes = len(r["episodes"])
    if total_episodes == 0:
        print("Nessun trade registrato in questa esecuzione.\n")
        continue

    total_wins = sum(s["wins"] for s in stats.values())
    total_losses = sum(s["losses"] for s in stats.values())
    win_rate = (total_wins / total_episodes) * 100
    profit_factor = (gross_profit / gross_loss) if gross_loss > 0 else float("inf")

    print(f"Performance Complessiva Trade:")
    print(f"  - Win Rate: {win_rate:.2f}% ({total_wins} Win, {total_losses} Loss)")
    print(f"  - PnL Netto cumulato dai trade: {tot_pnl:.2f} {r['currency']}")
    print(f"  - Gross Profit: +{gross_profit:.2f} {r['currency']} | Gross Loss: -{gross_loss:.2f} {r['currency']}")
    print(f"  - Profit Factor: {profit_factor:.2f}\n")

    print("Dettaglio per Tipologia di Uscita:")
    for m, d in stats.items():
        avg_p = d["pnl"] / d["count"] if d["count"] > 0 else 0
        wr = (d["wins"] / d["count"]) * 100 if d["count"] > 0 else 0
        avg_h = (sum(d["ores"]) / len(d["ores"])) if d["ores"] else 0
        print(f"  [{m}]")
        print(f"    Conteggio: {d['count']} ({d['count']/total_episodes*100:.1f}% dei trade)")
        print(f"    PnL Totale: {d['pnl']:.2f} {r['currency']} (Media trade: {avg_p:.2f} {r['currency']})")
        print(f"    Win Rate: {wr:.1f}%")
        if d["ores"]:
            print(f"    Durata media: {avg_h:.1f} ore ({avg_h/24:.1f} giorni)")
    print()

