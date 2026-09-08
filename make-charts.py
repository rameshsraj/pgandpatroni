#!/usr/bin/env python3
"""
make-charts.py

Generates the charts embedded in the two guides.

EVERY figure below is annotated with the evidence file it came from, so the
charts can be audited the same way the prose is. Nothing here is estimated or
illustrative. If a number is derived rather than captured, the comment says so.

Output:
  postgres-patroni-ha/docs/charts/*.png
  postgres-sharding-lab/docs/charts/*.png
"""

import pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

ROOT = pathlib.Path(__file__).parent
PATRONI_OUT = ROOT / "postgres-patroni-ha" / "docs" / "charts"
SHARD_OUT = ROOT / "postgres-sharding-lab" / "docs" / "charts"
for d in (PATRONI_OUT, SHARD_OUT):
    d.mkdir(parents=True, exist_ok=True)

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
    "grid.linestyle": "-",
    "figure.dpi": 200,
})


def save(fig, path, note):
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  {path.relative_to(ROOT)}  ({note})")


def label_bars(ax, bars, fmt="{:.0f}", dy=0):
    for b in bars:
        h = b.get_height()
        ax.annotate(fmt.format(h), (b.get_x() + b.get_width() / 2, h),
                    textcoords="offset points", xytext=(0, 3 + dy),
                    ha="center", fontsize=10, fontweight="bold")


# =====================================================================
# SHARDING CHARTS
# =====================================================================
print("Sharding charts:")

WORKERS = ["worker-1", "worker-2", "worker-3"]

# evidence/01-before-shard3/rows-per-worker-customers.txt  -> 241, 259 (no worker-3)
# evidence/02-after-rebalance/rows-per-worker-customers.txt -> 148, 168, 184
ROWS_BEFORE = [241, 259, 0]
ROWS_AFTER = [148, 168, 184]

# evidence/01-before-shard3/shard-count-per-worker.txt  -> 6, 6
# evidence/02-after-rebalance/shard-count-per-worker.txt -> 4, 4, 4
SHARDS_BEFORE = [6, 6, 0]
SHARDS_AFTER = [4, 4, 4]

# --- 1. Customer rows per worker, before and after -------------------
fig, ax = plt.subplots(figsize=(7.4, 4.1))
x = range(len(WORKERS))
w = 0.38
b1 = ax.bar([i - w / 2 for i in x], ROWS_BEFORE, w, label="Before rebalance", color=BLUE)
b2 = ax.bar([i + w / 2 for i in x], ROWS_AFTER, w, label="After rebalance", color=ORANGE)
label_bars(ax, b1)
label_bars(ax, b2)
ax.set_xticks(list(x))
ax.set_xticklabels(WORKERS)
ax.set_ylabel("Customer rows")
ax.set_title("Customer rows per worker, before and after the rebalance")
ax.set_ylim(0, 340)
ax.legend(frameon=False, loc="upper center", ncol=2, bbox_to_anchor=(0.5, 1.0))
ax.annotate("worker-3 joined holding\nno data at all",
            xy=(2 - w / 2, 3), xytext=(1.52, 78), fontsize=9, color=RED, ha="center",
            arrowprops=dict(arrowstyle="->", color=RED, lw=1.2,
                            connectionstyle="arc3,rad=-0.2"))
save(fig, SHARD_OUT / "rows-per-worker.png", "rows per worker before and after")

# --- 2. Shard count per worker, before and after ---------------------
fig, ax = plt.subplots(figsize=(7.2, 3.6))
b1 = ax.bar([i - w / 2 for i in x], SHARDS_BEFORE, w, label="Before rebalance", color=BLUE)
b2 = ax.bar([i + w / 2 for i in x], SHARDS_AFTER, w, label="After rebalance", color=ORANGE)
label_bars(ax, b1)
label_bars(ax, b2)
ax.set_xticks(list(x))
ax.set_xticklabels(WORKERS)
ax.set_ylabel("Shards held")
ax.set_title("Shards per worker: twelve shards over two workers, then three")
ax.set_ylim(0, 8)
ax.yaxis.set_major_locator(MaxNLocator(integer=True))
ax.legend(frameon=False, loc="upper right")
save(fig, SHARD_OUT / "shards-per-worker.png", "shard count before and after")

# --- 3. Rows per shard, coloured by what moved ----------------------
# Per shard counts came from the inspection script during the session, not from
# the evidence snapshots. They are included because they reconcile exactly
# against the five captured totals above (241, 259, 148, 168, 184 and 500).
SHARD_IDS = [102008, 102009, 102010, 102011, 102012, 102013,
             102014, 102015, 102016, 102017, 102018, 102019]
SHARD_ROWS = [46, 41, 32, 44, 47, 47, 32, 47, 39, 35, 45, 45]
# evidence/02-after-rebalance/shard-placement.txt: these four ended on worker-3
MOVED = {102008, 102011, 102012, 102013}

assert sum(SHARD_ROWS) == 500
assert sum(r for s, r in zip(SHARD_IDS, SHARD_ROWS) if s in MOVED) == 184

fig, ax = plt.subplots(figsize=(7.6, 4.1))
colors = [PURPLE if s in MOVED else GREY for s in SHARD_IDS]
bars = ax.bar([str(s) for s in SHARD_IDS], SHARD_ROWS, color=colors, width=0.68)
label_bars(ax, bars)
avg = 500 / 12
ax.axhline(avg, color=RED, ls="--", lw=1.3)
ax.annotate(f"an even split would be {avg:.1f} rows per shard",
            xy=(2.0, avg), xytext=(2.0, avg + 12.5), fontsize=9, color=RED,
            ha="center",
            arrowprops=dict(arrowstyle="->", color=RED, lw=1.1))
ax.set_ylabel("Customer rows in the shard")
ax.set_title("Rows in each of the twelve shards, and which four moved")
ax.set_ylim(0, 58)
plt.setp(ax.get_xticklabels(), rotation=45, ha="right", fontsize=9)
from matplotlib.patches import Patch
ax.legend(handles=[Patch(color=PURPLE, label="Moved to worker-3 (184 rows)"),
                   Patch(color=GREY, label="Stayed where it was (316 rows)")],
          frameon=False, loc="upper left", fontsize=9)
save(fig, SHARD_OUT / "rows-per-shard.png", "hash skew and which shards moved")

# --- 4. Row totals unchanged ---------------------------------------
# evidence/*/total-row-counts.txt in both phases: 500, 2500, 7500
TABLES = ["customers", "orders", "order_items"]
TOTALS_BEFORE = [500, 2500, 7500]
TOTALS_AFTER = [500, 2500, 7500]
fig, ax = plt.subplots(figsize=(7.2, 3.6))
xt = range(len(TABLES))
b1 = ax.bar([i - w / 2 for i in xt], TOTALS_BEFORE, w, label="Before rebalance", color=BLUE)
b2 = ax.bar([i + w / 2 for i in xt], TOTALS_AFTER, w, label="After rebalance", color=GREEN)
label_bars(ax, b1)
label_bars(ax, b2)
ax.set_xticks(list(xt))
ax.set_xticklabels(TABLES)
ax.set_ylabel("Total rows")
ax.set_title("Total rows per table: identical before and after the move")
ax.set_ylim(0, 9000)
ax.legend(frameon=False, loc="upper left")
ax.text(0.99, 0.9, "10,500 rows either way", transform=ax.transAxes,
        ha="right", fontsize=10, fontweight="bold", color=GREEN)
save(fig, SHARD_OUT / "row-totals.png", "totals unchanged")


# =====================================================================
# PATRONI CHARTS
# =====================================================================
print("Patroni charts:")

# All timestamps below are from test-results/failover-events/*.txt except the
# stop time, which is from the command output. Seconds are relative to the stop.
#   14:51:58        primary container stopped        (command output)
#   14:52:23.837    cluster seen as unlocked         (pg-node-1 log)
#   14:52:31.980    promoted self to leader          (pg-node-1 log)
#   14:52:32.087    leader lock updated              (pg-node-1 log)
T_STOP = 0.0
T_UNLOCKED = 25.837
T_PROMOTED = 33.980
T_LOCK_UPDATED = 34.087
HAPROXY_MAX = 3.0   # derived from "inter 3s" in haproxy.cfg, not measured

# --- 5. Where the failover time went -------------------------------
# The promotion lasted 0.107s, which is invisible on a 37 second axis, so it is
# drawn as a marker with a callout rather than as a bar segment.
fig, ax = plt.subplots(figsize=(7.8, 3.1))
# label_y staggers the captions so the two narrow phases do not collide
phases = [
    ("Leader lock still valid\n(30s from its last renewal)", T_STOP, T_UNLOCKED - T_STOP, ORANGE, False, 0.27, 0),
    ("Patroni waiting for\nits next loop pass", T_UNLOCKED, T_PROMOTED - T_UNLOCKED, BLUE, False, 0.27, 0),
    ("HAProxy health check\n(derived, up to 3s)", T_LOCK_UPDATED, HAPROXY_MAX, GREY, True, 0.72, 2.0),
]
for label, start, dur, color, hatched, label_y, label_dx in phases:
    ax.barh(0, dur, left=start, height=0.40, color=color,
            hatch="//" if hatched else None,
            edgecolor="white" if not hatched else "#607D8B", linewidth=1.2)
    ax.annotate(f"{dur:.1f}s", (start + dur / 2, 0), ha="center", va="center",
                fontsize=10, fontweight="bold",
                color="white" if not hatched else "#37474F")
    ax.annotate(label, (start + dur / 2 + label_dx, label_y), ha="center",
                va="bottom", fontsize=8.5,
                arrowprops=dict(arrowstyle="-", color="#90A4AE", lw=0.8,
                                shrinkA=2, shrinkB=2) if label_dx else None,
                xytext=(start + dur / 2 + label_dx, label_y) if label_dx else None)

# promotion marker and callout
ax.annotate("the promotion itself took 0.11s",
            xy=(T_PROMOTED, -0.21), xytext=(T_PROMOTED - 9.0, -0.72),
            fontsize=9, color=GREEN, fontweight="bold", ha="center",
            arrowprops=dict(arrowstyle="->", color=GREEN, lw=1.3))

ax.set_yticks([])
ax.set_xlim(-1.5, 39)
ax.set_ylim(-0.85, 1.30)
ax.set_xlabel("Seconds after the primary container was stopped")
ax.set_title("Where the 34 seconds went, and none of it was PostgreSQL")
ax.grid(axis="y", visible=False)
for xv, lab in [(0, "stop"), (T_UNLOCKED, "lock expired"), (T_PROMOTED, "new primary")]:
    ax.axvline(xv, color="#37474F", lw=0.8, ls=":")
    ax.annotate(lab, (xv, -0.30), ha="center", fontsize=8.5, color="#37474F")
save(fig, PATRONI_OUT / "failover-time-breakdown.png", "34 second breakdown")

# --- 6. Cluster size through the test ------------------------------
# From the patroni-list snapshots in before-failover, after-failover and
# after-recovery. Node counts are exact; these are the three captured states.
PHASES = ["Before the\nfailover", "After the\nfailover", "After the old\nprimary rejoined"]
TOTAL_NODES = [3, 2, 3]        # members listed by patronictl
PRIMARIES = [1, 1, 1]
REPLICAS = [2, 1, 2]
fig, ax = plt.subplots(figsize=(7.2, 3.7))
xp = range(len(PHASES))
p1 = ax.bar(list(xp), PRIMARIES, 0.5, label="Primary (accepts writes)", color=GREEN)
p2 = ax.bar(list(xp), REPLICAS, 0.5, bottom=PRIMARIES, label="Replicas (streaming)", color=BLUE)
for i, tot in enumerate(TOTAL_NODES):
    ax.annotate(f"{tot} node{'s' if tot > 1 else ''}", (i, tot), ha="center",
                textcoords="offset points", xytext=(0, 4),
                fontsize=10, fontweight="bold")
ax.set_xticks(list(xp))
ax.set_xticklabels(PHASES)
ax.set_ylabel("Cluster members")
ax.set_title("A primary existed at every point, but redundancy did not")
ax.set_ylim(0, 4)
ax.yaxis.set_major_locator(MaxNLocator(integer=True))
ax.legend(frameon=False, loc="upper right", fontsize=9)
ax.annotate("no spare node to\nfail over to here", xy=(1.26, 1.55), xytext=(1.72, 2.55),
            fontsize=9, color=RED, ha="center",
            arrowprops=dict(arrowstyle="->", color=RED, lw=1.2,
                            connectionstyle="arc3,rad=0.2"))
save(fig, PATRONI_OUT / "cluster-size-through-test.png", "captured cluster states")

# --- Chart 7 was removed on purpose ------------------------------
# An earlier version compared the measured 1.46s clean rejoin against an
# 'abrupt loss' case. Drawing a bar for that second case implies a duration
# that was never measured in this run, so the chart was dropped rather than
# invent a number. The 1.46s figure appears in the prose instead.

print("\nDone.")


# =====================================================================
# COMBINED ARCHITECTURE ARTICLE
# =====================================================================
# NOTE ON PROVENANCE: the combined architecture has NOT been built or
# measured. The only chart here is node count arithmetic derived from the
# topology itself, which is countable rather than measured. No performance
# or timing chart is drawn for the combined design, because there is no
# captured run to draw it from.
print("Combined article chart:")

COMBINED_OUT = ROOT / "docs" / "charts"
COMBINED_OUT.mkdir(parents=True, exist_ok=True)

topos = [
    "Sharding lab\nas built",
    "Patroni lab\nas built",
    "Combined,\nminimum",
    "Combined,\nrecommended",
]
# PostgreSQL nodes, then DCS nodes. Arithmetic of each topology.
#   sharding lab   : 1 coordinator + 3 workers, no DCS                  = 4 + 0
#   patroni lab    : 3 PostgreSQL, 1 etcd                               = 3 + 1
#   combined min   : coordinator 2 + (3 worker groups x 2), etcd 3       = 8 + 3
#   combined rec   : coordinator 3 + (3 worker groups x 3), etcd 3       = 12 + 3
pg_nodes  = [4, 3, 8, 12]
dcs_nodes = [0, 1, 3, 3]
# Redundant copies of any given shard or row range
redundancy = ["none", "2 replicas", "1 replica", "2 replicas"]

fig, ax = plt.subplots(figsize=(7.6, 4.2))
xc = range(len(topos))
b1 = ax.bar(list(xc), pg_nodes, 0.55, label="PostgreSQL nodes", color=BLUE)
b2 = ax.bar(list(xc), dcs_nodes, 0.55, bottom=pg_nodes, label="etcd nodes", color=PURPLE)
for i,(a,b) in enumerate(zip(pg_nodes, dcs_nodes)):
    ax.annotate(f"{a+b} total", (i, a+b), ha="center", textcoords="offset points",
                xytext=(0,5), fontsize=10, fontweight="bold")
    ax.annotate(redundancy[i], (i, 0.4), ha="center", fontsize=9, color="white",
                fontweight="bold")
ax.set_xticks(list(xc)); ax.set_xticklabels(topos)
ax.set_ylabel("Nodes to run and pay for")
ax.set_title("What high availability plus sharding actually costs in nodes")
ax.set_ylim(0, 19)
ax.yaxis.set_major_locator(MaxNLocator(integer=True))
ax.legend(frameon=False, loc="upper left")
ax.text(0.99, 0.03, "Counted from each topology, not measured",
        transform=ax.transAxes, ha="right", fontsize=8.5, color="#666")
save(fig, COMBINED_OUT / "node-count-by-topology.png", "node arithmetic, not measured")
