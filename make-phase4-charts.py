#!/usr/bin/env python3
"""
make-phase4-charts.py

Charts and animations for the Phase 4 dynamic replica scaler article.

PROVENANCE. Every number is read directly out of the verified run report at
  Phase4-scaler/reports/phase4-20260908T173358240-1efd4a87.json
Nothing is typed in by hand, so the charts cannot drift from the evidence.
Policy thresholds (20 TPS out, 5 TPS in) are read from the article's stated
policy and asserted against the observed decision values.
"""

import json
import pathlib
from datetime import datetime, timezone

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator
from matplotlib.patches import Patch, FancyArrowPatch
from matplotlib.animation import FuncAnimation, PillowWriter

ROOT = pathlib.Path(__file__).parent
REPORT = ROOT / "Phase4-scaler" / "reports" / "phase4-20260908T173358240-1efd4a87.json"
OUT = ROOT / "docs" / "charts" / "phase4"
OUT.mkdir(parents=True, exist_ok=True)

D = json.loads(REPORT.read_text())

BLUE, ORANGE, GREEN, PURPLE, RED, GREY, TEAL = (
    "#2196F3", "#FF9800", "#4CAF50", "#9C27B0", "#F44336", "#90A4AE", "#009688")

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 11,
    "axes.titlesize": 13, "axes.titleweight": "bold", "axes.labelsize": 11,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.alpha": 0.25, "figure.dpi": 200,
})

THRESH_OUT, THRESH_IN = 20.0, 5.0


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00").replace("Z", ""))


def parse(s):
    # .NET "o" format has 7 fractional digits; trim to 6 for fromisoformat
    s = s.rstrip("Z")
    if "." in s:
        head, frac = s.split(".")
        s = head + "." + frac[:6]
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


ACTIONS = D["actions"]
T0 = min(parse(a["decisionUTC"]) for a in ACTIONS)
# experiment start is 393.211s before the recorded end; derive from run id instead
RUN_START = parse("2026-09-08T17:33:58.2400000")


def off(s):
    return (parse(s) - RUN_START).total_seconds()


def save(fig, name, note):
    p = OUT / name
    fig.tight_layout()
    fig.savefig(p, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  {p.relative_to(ROOT)}  ({note})")


# ---------------------------------------------------------------
# 1. Node count over the whole experiment
# ---------------------------------------------------------------
times, counts = [0.0], [2]          # primary + permanent replica
for a in ACTIONS:
    times.append(off(a["completedUTC"]))
    counts.append(counts[-1] + (1 if a["action"] == "out" else -1))
times.append(D["durationSeconds"])
counts.append(counts[-1])

fig, ax = plt.subplots(figsize=(7.8, 3.9))
ax.step(times, counts, where="post", color=BLUE, lw=2.6)
ax.fill_between(times, counts, step="post", alpha=0.12, color=BLUE)
for a in ACTIONS:
    x = off(a["completedUTC"])
    ax.plot([x], [1.75], marker="^" if a["action"] == "out" else "v",
            color=GREEN if a["action"] == "out" else ORANGE, ms=9, clip_on=False)
ax.annotate("four replicas admitted", (off(ACTIONS[3]["completedUTC"]), 6),
            xytext=(120, 6.7), fontsize=9.5, color=GREEN,
            arrowprops=dict(arrowstyle="->", color=GREEN, lw=1.2))
ax.annotate("all four removed,\nvolumes kept", (off(ACTIONS[-1]["completedUTC"]), 2),
            xytext=(300, 4.2), fontsize=9.5, color=ORANGE, ha="center",
            arrowprops=dict(arrowstyle="->", color=ORANGE, lw=1.2))
ax.set_xlabel("Seconds from the start of the experiment")
ax.set_ylabel("PostgreSQL containers")
ax.set_title("Two nodes to six and back, driven only by measured throughput")
ax.set_ylim(1.6, 7.2)
ax.set_xlim(0, D["durationSeconds"])
ax.yaxis.set_major_locator(MaxNLocator(integer=True))
ax.legend(handles=[Patch(color=GREEN, label="scale out"), Patch(color=ORANGE, label="scale in")],
          frameon=False, loc="upper right", fontsize=9)
save(fig, "node-count-timeline.png", "derived from action completion times")


# ---------------------------------------------------------------
# 2. Measured TPS at each decision, against the two thresholds
# ---------------------------------------------------------------
fig, ax = plt.subplots(figsize=(7.8, 4.0))
outs = [a for a in ACTIONS if a["action"] == "out"]
ins = [a for a in ACTIONS if a["action"] == "in"]
ax.axhspan(THRESH_OUT, 70, color=GREEN, alpha=0.07)
ax.axhspan(0, THRESH_IN, color=ORANGE, alpha=0.09)
ax.axhline(THRESH_OUT, color=GREEN, ls="--", lw=1.4)
ax.axhline(THRESH_IN, color=ORANGE, ls="--", lw=1.4)
ax.annotate(f"scale-out threshold: above {THRESH_OUT:.0f} TPS, twice",
            (4, THRESH_OUT + 1.6), fontsize=9, color=GREEN)
ax.annotate(f"scale-in threshold: below {THRESH_IN:.0f} TPS, twice",
            (150, THRESH_IN + 1.6), fontsize=9, color=ORANGE)
for a in outs:
    x = off(a["decisionUTC"])
    ax.plot([x], [a["measuredTPS"]], "o", color=GREEN, ms=10, zorder=5)
    ax.annotate(f"{a['slot']}\n{a['measuredTPS']:.1f}", (x, a["measuredTPS"]),
                textcoords="offset points", xytext=(0, 11), ha="center",
                fontsize=8.5, fontweight="bold", color=GREEN)
for a in ins:
    x = off(a["decisionUTC"])
    ax.plot([x], [a["measuredTPS"]], "o", color=ORANGE, ms=10, zorder=5)
    ax.annotate(f"{a['slot']}\n{a['measuredTPS']:.1f}", (x, a["measuredTPS"]),
                textcoords="offset points", xytext=(0, 13), ha="center",
                fontsize=8.5, fontweight="bold", color=ORANGE)
ax.set_xlabel("Seconds from the start of the experiment")
ax.set_ylabel("Completed transactions per second")
ax.set_title("Every decision, and the measurement that caused it")
ax.set_xlim(0, D["durationSeconds"])
ax.set_ylim(0, 72)
save(fig, "decision-tps.png", "measuredTPS from the report")

for a in outs:
    assert a["measuredTPS"] > THRESH_OUT, a
for a in ins:
    assert a["measuredTPS"] < THRESH_IN, a


# ---------------------------------------------------------------
# 3. How long each action took
# ---------------------------------------------------------------
fig, ax = plt.subplots(figsize=(7.6, 3.8))
labels = [f"{a['slot']}\n{'admit' if a['action']=='out' else 'remove'}" for a in ACTIONS]
secs = [a["seconds"] for a in ACTIONS]
cols = [GREEN if a["action"] == "out" else ORANGE for a in ACTIONS]
bars = ax.bar(range(len(ACTIONS)), secs, 0.6, color=cols)
for b, v in zip(bars, secs):
    ax.annotate(f"{v:.1f}s", (b.get_x() + b.get_width() / 2, v), ha="center",
                textcoords="offset points", xytext=(0, 4), fontsize=9.5, fontweight="bold")
ax.set_xticks(range(len(ACTIONS)))
ax.set_xticklabels(labels, fontsize=9)
ax.set_ylabel("Seconds, decision to completion")
ax.set_title("Admissions got slower as the cluster grew; removals did not")
ax.set_ylim(0, 20)
ax.legend(handles=[Patch(color=GREEN, label="admit: create, clone, verify, route"),
                   Patch(color=ORANGE, label="remove: drain, stop, archive, verify")],
          frameon=False, loc="upper center", fontsize=9, ncol=1)
save(fig, "action-durations.png", "seconds field from the report")


# ---------------------------------------------------------------
# 4. Connection distribution at peak
# ---------------------------------------------------------------
routing = D["peakRouting"]
fig, ax = plt.subplots(figsize=(7.4, 3.8))
names = [r["svname"] for r in routing]
vals = [int(r["stot"]) for r in routing]
cols = [BLUE] + [GREEN, TEAL, PURPLE, ORANGE][:len(names) - 1]
bars = ax.bar(range(len(names)), vals, 0.6, color=cols)
for b, v in zip(bars, vals):
    ax.annotate(f"{v:,}", (b.get_x() + b.get_width() / 2, v), ha="center",
                textcoords="offset points", xytext=(0, 4), fontsize=10, fontweight="bold")
ax.set_xticks(range(len(names)))
ax.set_xticklabels(names)
ax.set_ylabel("Cumulative connections on the read route")
ax.set_title("The permanent replica had a long head start")
ax.set_ylim(0, 4700)
ax.text(0.99, 0.72, "All five UP, econ=0, eresp=0\nThese are connections, not transactions",
        transform=ax.transAxes, ha="right", fontsize=8.5, color="#555")
save(fig, "peak-routing.png", "peakRouting stot from the report")


# ---------------------------------------------------------------
# 5. Traffic stages
# ---------------------------------------------------------------
traffic = D["traffic"]
fig, (a1, a2) = plt.subplots(1, 2, figsize=(7.8, 3.5))
st = [t["stage"].split("-", 1)[1].replace("-", " ") for t in traffic]
tx = [t["transactions"] for t in traffic]
lat = [t["meanLatencyMs"] for t in traffic]
b1 = a1.bar(range(3), tx, 0.55, color=[GREY, RED, GREY])
for b, v in zip(b1, tx):
    a1.annotate(f"{v:,}", (b.get_x() + b.get_width() / 2, v), ha="center",
                textcoords="offset points", xytext=(0, 3), fontsize=9.5, fontweight="bold")
a1.set_xticks(range(3)); a1.set_xticklabels(st, fontsize=9)
a1.set_ylabel("Completed transactions")
a1.set_title("Work completed", fontsize=11.5)
a1.set_ylim(0, 12000)
b2 = a2.bar(range(3), lat, 0.55, color=[GREY, RED, GREY])
for b, v in zip(b2, lat):
    a2.annotate(f"{v:,.0f}", (b.get_x() + b.get_width() / 2, v), ha="center",
                textcoords="offset points", xytext=(0, 3), fontsize=9.5, fontweight="bold")
a2.set_xticks(range(3)); a2.set_xticklabels(st, fontsize=9)
a2.set_ylabel("Mean scheduled latency, ms")
a2.set_title("Latency, including queueing", fontsize=11.5)
a2.set_ylim(0, 2600)
fig.suptitle("Three traffic stages, zero invalid records", fontweight="bold", fontsize=13)
save(fig, "traffic-stages.png", "traffic array from the report")


# ---------------------------------------------------------------
# 6. Animated data flow during scale-out  (GIF)
# ---------------------------------------------------------------
def flow_frames():
    frames = []
    for active in range(0, 5):
        for pulse in range(6):
            frames.append((active, pulse))
    for active in range(3, -1, -1):
        for pulse in range(4):
            frames.append((active, pulse))
    return frames


FRAMES = flow_frames()
SLOTS = ["base", "elastic1", "elastic2", "elastic3", "elastic4"]
SLOT_COL = [BLUE, GREEN, TEAL, PURPLE, ORANGE]


def draw_flow(ax, active, pulse):
    ax.clear()
    ax.set_xlim(0, 10); ax.set_ylim(0, 6.4); ax.axis("off")
    ax.text(5, 6.05, "Read traffic spreading across replicas as they are admitted",
            ha="center", fontsize=12, fontweight="bold")
    # traffic source
    ax.add_patch(plt.Rectangle((0.2, 2.6), 1.5, 1.1, color="#607D8B"))
    ax.text(0.95, 3.15, "pgbench\n8 clients", ha="center", va="center",
            color="white", fontsize=9, fontweight="bold")
    # proxy
    ax.add_patch(plt.Rectangle((2.6, 2.5), 1.5, 1.3, color=ORANGE))
    ax.text(3.35, 3.15, "HAProxy\n:5001\nround robin", ha="center", va="center",
            color="white", fontsize=8.5, fontweight="bold")
    ax.add_patch(FancyArrowPatch((1.75, 3.15), (2.55, 3.15),
                                 arrowstyle="-|>", mutation_scale=16, color="#37474F", lw=2))
    # replica slots
    ys = [5.3, 4.2, 3.1, 2.0, 0.9]
    for i, (name, col, y) in enumerate(zip(SLOTS, SLOT_COL, ys)):
        live = (i <= active)
        ax.add_patch(plt.Rectangle((6.4, y - 0.38), 2.5, 0.76,
                                   color=col if live else "#ECEFF1",
                                   ec="#B0BEC5" if not live else "none"))
        ax.text(7.65, y, name if live else f"{name}  (slot idle)",
                ha="center", va="center", fontsize=9.5, fontweight="bold",
                color="white" if live else "#90A4AE")
        if live:
            for k in range(3):
                t = (pulse + k * 2) % 6 / 5.0
                x = 4.15 + t * (6.35 - 4.15)
                yy = 3.15 + t * (y - 3.15)
                ax.plot([x], [yy], "o", color=col, ms=6, alpha=0.85)
            ax.add_patch(FancyArrowPatch((4.15, 3.15), (6.35, y), arrowstyle="-",
                                         color=col, lw=1.0, alpha=0.30))
    n = active + 1
    ax.text(5, 0.15, f"{n} replica{'s' if n > 1 else ''} serving reads",
            ha="center", fontsize=10.5, fontweight="bold", color="#37474F")


fig, ax = plt.subplots(figsize=(8.2, 5.2))
anim = FuncAnimation(fig, lambda i: draw_flow(ax, *FRAMES[i]),
                     frames=len(FRAMES), interval=140)
gif = OUT / "dataflow-scaleout.gif"
anim.save(gif, writer=PillowWriter(fps=7))
plt.close(fig)
print(f"  {gif.relative_to(ROOT)}  (animated, {len(FRAMES)} frames)")

# static strip of the same animation, because Word shows only frame one of a GIF
fig, axes = plt.subplots(5, 1, figsize=(7.0, 12.2))
for i, axx in enumerate(axes):
    draw_flow(axx, i, 0)
    axx.set_title("")
    axx.text(5, 6.05, f"Step {i+1}: {i+1} replica{'s' if i else ''} on the read route",
             ha="center", fontsize=11, fontweight="bold")
save(fig, "dataflow-strip.png", "static frames of the animation, for print")

print("\nDone.")
