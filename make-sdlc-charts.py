#!/usr/bin/env python3
"""
make-sdlc-charts.py

Charts for the article reviewing Google's "The New SDLC With Vibe Coding".

PROVENANCE NOTE. These are not measurements of anything I ran. Each chart
below records where its numbers come from:

  - Adoption figures are quoted from the whitepaper (via the lead author's
    companion post), for early 2026.
  - The productivity contrast quotes two named sources that disagree.
  - The cost-of-ownership chart is deliberately drawn with NO numbers on the
    vertical axis, because the paper's own author states the "3 to 10x"
    crossover is illustrative rather than a measured constant. Drawing it with
    a scale would invent precision that does not exist.
"""

import pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = pathlib.Path(__file__).parent
OUT = ROOT / "docs" / "charts"
OUT.mkdir(parents=True, exist_ok=True)

BLUE, ORANGE, GREEN, PURPLE, RED, GREY = (
    "#2196F3", "#FF9800", "#4CAF50", "#9C27B0", "#F44336", "#90A4AE")

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 11,
    "axes.titlesize": 13,
    "axes.titleweight": "bold",
    "axes.labelsize": 11,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": True,
    "grid.alpha": 0.25,
    "figure.dpi": 200,
})


def save(fig, path, note):
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  {path.relative_to(ROOT)}  ({note})")


# --- 1. Cost of ownership, shape only -------------------------------
# No vertical scale on purpose. The crossover is illustrative per the author.
fig, ax = plt.subplots(figsize=(7.4, 4.0))
x = [i / 100 for i in range(0, 101)]
vibe = [0.4 + 5.2 * (t ** 1.9) for t in x]          # cheap start, steep climb
agentic = [1.9 + 1.15 * t for t in x]                # costly start, flat run
ax.plot(x, vibe, color=RED, lw=2.6, label="Skip the structure")
ax.plot(x, agentic, color=BLUE, lw=2.6, label="Build the structure first")

# crossover marker
cx = next(t for t, v, a in zip(x, vibe, agentic) if v >= a)
cy = 1.9 + 1.15 * cx
ax.plot([cx], [cy], "o", color="#37474F", ms=8, zorder=5)
ax.annotate("the lines cross here", (cx, cy), xytext=(cx - 0.42, cy + 1.5),
            fontsize=9.5, color="#37474F",
            arrowprops=dict(arrowstyle="->", color="#37474F", lw=1.2))

ax.annotate("cheap to start", (0.03, 0.55), fontsize=9, color=RED)
ax.annotate("token burn,\nrework, cleanup", (0.60, 5.3), fontsize=9, color=RED, ha="center")
ax.annotate("specs, tests,\nharness up front", (0.06, 2.35), fontsize=9, color=BLUE)
ax.annotate("low cost per\nfeature after", (0.88, 3.55), fontsize=9, color=BLUE, ha="center")

ax.set_xlabel("Features shipped, over time")
ax.set_ylabel("Cumulative cost of ownership")
ax.set_title("The cheap option and the expensive one swap places")
ax.set_yticks([])
ax.set_xticks([])
ax.set_ylim(0, 7)
ax.legend(frameon=False, loc="upper left")
ax.text(0.99, 0.02, "Shape only. No scale, because the crossover point is illustrative.",
        transform=ax.transAxes, ha="right", fontsize=8.5, color="#666")
save(fig, OUT / "sdlc-cost-crossover.png", "shape only, no scale")


# --- 2. Adoption, early 2026 ----------------------------------------
labels = ["Use coding agents\nregularly", "Use them\nevery day", "New code that is\nAI generated"]
vals = [85, 51, 41]
fig, ax = plt.subplots(figsize=(7.0, 3.6))
bars = ax.bar(range(len(labels)), vals, 0.5, color=[BLUE, PURPLE, ORANGE])
for b, v in zip(bars, vals):
    ax.annotate(f"{v}%", (b.get_x() + b.get_width() / 2, v), ha="center",
                textcoords="offset points", xytext=(0, 4),
                fontsize=12, fontweight="bold")
ax.set_xticks(range(len(labels)))
ax.set_xticklabels(labels)
ax.set_ylabel("Share of professional developers")
ax.set_ylim(0, 100)
ax.set_title("Where adoption stood in early 2026")
ax.text(0.99, 0.93, "Figures quoted from the whitepaper",
        transform=ax.transAxes, ha="right", fontsize=8.5, color="#666")
save(fig, OUT / "sdlc-adoption.png", "quoted from the paper")


# --- 3. The two productivity findings -------------------------------
fig, ax = plt.subplots(figsize=(7.4, 2.9))
ax.barh(["Survey range\nacross studies"], [32], height=0.5, color=GREEN,
        xerr=[[7], [7]], capsize=6, error_kw=dict(ecolor="#2E7D32", lw=1.6))
ax.annotate("25 to 39% faster", (39.5, 0), textcoords="offset points", xytext=(10, 0),
            va="center", fontsize=10.5, fontweight="bold", color=GREEN)
ax.barh(["Controlled study,\nexperienced devs"], [-19], height=0.5, color=RED)
ax.annotate("19% slower once review\nand rework are counted", (-19, 1),
            textcoords="offset points", xytext=(-14, 0), va="center", ha="right",
            fontsize=10, fontweight="bold", color=RED)
ax.axvline(0, color="#37474F", lw=1)
ax.set_xlim(-62, 78)
ax.set_xlabel("Change in delivery speed")
ax.set_title("Both of these findings are real, which is the point")
ax.grid(axis="y", visible=False)
ax.set_xticks([])
save(fig, OUT / "sdlc-productivity.png", "two cited findings that disagree")

print("\nDone.")
