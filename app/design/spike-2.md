# Spike #2 — Qt Quick packet table at 10k packets/s

Status: **passed** (2026-10-22)

## Question

Can the Qt Quick packet table sustain the daemon's 10k+ packets/s live stream
with smooth scrolling and bounded UI cost, and which table primitive should the
production UI use?

## Method

`app/src/benchmark.cpp` drives a C++ `QAbstractListModel` with a synthetic,
deterministic stream at the requested pps (default 10,000) and measures:

- `insert_*` — time spent in `beginInsertRows`/`endInsertRows` batches (this
  includes the view's synchronous row handling);
- frame intervals from `QQuickWindow::frameSwapped` (p50/p99/max, average FPS);
- RSS from `/proc/self/status` (Qt's `atEnd()` is unreliable on procfs).

Rows are inserted every 16 ms (≈160 packets per batch), with "follow" mode
keeping the view pinned to the newest packet — the live-capture behaviour.
Two implementations share the same column layout and row model:

| Variant | File | Structure |
|---|---|---|
| A | `app/qml/PacketTableListView.qml` | `ListView` + composite row delegate (Repeater over columns) |
| B | `app/qml/PacketTableView.qml` | Qt Quick Controls `TableView` + per-cell delegates |

Run (Wayland session, Release build, Qt 6.11.2):

```sh
TCPVIEWER_SPIKE=1 TCPVIEWER_SPIKE_VIEW=table \
TCPVIEWER_SPIKE_SECONDS=5 TCPVIEWER_SPIKE_OUT=/tmp/spike.json \
./app/build/omarchy-tcpviewer
```

`TCPVIEWER_SPIKE_FOLLOW=0` disables end-following; `TCPVIEWER_SPIKE_PPS`
changes the rate. The app exits when the run finishes and writes a `BENCH:`
JSON line to `TCPVIEWER_SPIKE_OUT` (Qt's stderr sink is unusable under some
tooling).

## Results (10,000 pps, ~3 s runs unless noted)

| Variant | Follow | Avg FPS | Frame p50 | Frame p99 | Frame max | Insert avg | Insert max |
|---|---|---|---|---|---|---|---|
| ListView | yes | **10.6** | 90.4 ms | 378.1 ms | 378.1 ms | 25.2 ms | 106.4 ms |
| ListView | no | 45.3 | 16.8 ms | 113.9 ms | 405.7 ms | 5.6 ms | 76.6 ms |
| TableView | yes | **57.5** | 16.6 ms | 43.1 ms | 48.4 ms | 4.0 ms | 33.1 ms |
| TableView | no | 56.7 | 16.4 ms | 52.9 ms | 55.6 ms | 4.3 ms | 41.2 ms |

5 s confirmation (TableView, follow, 48,790 rows): 55.5 FPS, frame p50 16.6 ms,
p99 70.2 ms, insert avg 4.4 ms; RSS 102 MB → 169 MB (~1.4 KB/row including
delegates and QString data).

## Interpretation

- `ListView.positionViewAtEnd()` on every batch is the pathological path
  (10.6 FPS); the same view without following reaches 45 FPS. The composite row
  delegate also costs more than TableView's cell delegates with item reuse.
- `TableView` stays at vsync (≈57 FPS) while following live data and keeps
  insert batches around 4 ms. Occasional 40–100 ms frames remain (row string
  allocation and infrequent cache churn) and are acceptable for the baseline;
  later work can coalesce inserts further under load.
- Memory is ~1.4 KB/row, so the GUI must inherit the daemon's capture
  retention policy (or page old rows) for very large captures, as upstream does.

## Decision

Use **Qt Quick Controls TableView with per-cell delegates** as the production
packet table (`app/qml/PacketTableView.qml`). The ListView variant stays in the
tree only as the benchmark's comparison case (header comment marks it rejected).
