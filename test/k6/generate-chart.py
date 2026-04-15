#!/usr/bin/env python3
"""
Parse k6 JSON output files and generate an HTML chart with Chart.js.
Groups http_req_duration data points into 1-second buckets,
calculates p50/p95/avg per bucket, and plots latency + VU count over time.

Usage: python3 generate-chart.py /tmp/k6-classic_kahadb.json /tmp/k6-classic_jdbc.json ...
"""

import json
import sys
import os
from collections import defaultdict
from datetime import datetime

COLORS = {
    "classic_kahadb": {"line": "rgba(54, 162, 235, 1)", "fill": "rgba(54, 162, 235, 0.1)"},
    "classic_jdbc": {"line": "rgba(255, 159, 64, 1)", "fill": "rgba(255, 159, 64, 0.1)"},
    "artemis_openwire": {"line": "rgba(75, 192, 192, 1)", "fill": "rgba(75, 192, 192, 0.1)"},
    "artemis_native": {"line": "rgba(255, 99, 132, 1)", "fill": "rgba(255, 99, 132, 0.1)"},
}

LABELS = {
    "classic_kahadb": "Classic KahaDB",
    "classic_jdbc": "Classic JDBC",
    "artemis_openwire": "Artemis (OpenWire)",
    "artemis_native": "Artemis (native)",
}


def parse_k6_json(filepath):
    """Extract http_req_duration and vus data points, bucketed per second."""
    durations = defaultdict(list)  # second_offset -> [durations_ms]
    vus = {}  # second_offset -> vu_count
    min_time = None

    with open(filepath) as f:
        for line in f:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue

            if row.get("type") != "Point":
                continue

            metric = row.get("metric", "")
            data = row.get("data", {})
            ts = data.get("time", "")
            value = data.get("value", 0)

            if not ts:
                continue

            # Parse ISO timestamp to epoch seconds
            try:
                # Handle timezone offset format
                t = datetime.fromisoformat(ts)
                epoch = t.timestamp()
            except (ValueError, TypeError):
                continue

            if min_time is None:
                min_time = epoch
            second = int(epoch - min_time)

            if metric == "http_req_duration":
                durations[second].append(value)
            elif metric == "vus":
                vus[second] = int(value)

    return durations, vus, min_time


def percentile(data, p):
    """Calculate percentile from sorted list."""
    if not data:
        return 0
    k = (len(data) - 1) * p / 100
    f = int(k)
    c = f + 1
    if c >= len(data):
        return data[f]
    return data[f] + (k - f) * (data[c] - data[f])


def aggregate_buckets(durations):
    """Compute per-second aggregates: count, avg, p50, p95, max."""
    result = {}
    for sec, vals in sorted(durations.items()):
        vals.sort()
        result[sec] = {
            "count": len(vals),
            "avg": sum(vals) / len(vals),
            "p50": percentile(vals, 50),
            "p95": percentile(vals, 95),
            "max": max(vals),
        }
    return result


def generate_html(datasets, output_path):
    """Generate HTML page with Chart.js charts."""
    # Build time labels (union of all second offsets)
    all_seconds = set()
    for d in datasets.values():
        all_seconds.update(d["agg"].keys())
    max_sec = max(all_seconds) if all_seconds else 80
    labels = list(range(0, max_sec + 1))

    # Build chart datasets for p95 latency
    p95_datasets = []
    avg_datasets = []
    rps_datasets = []
    for name, d in datasets.items():
        color = COLORS.get(name, {"line": "gray", "fill": "rgba(128,128,128,0.1)"})
        label = LABELS.get(name, name)
        agg = d["agg"]

        p95_data = [round(agg[s]["p95"], 1) if s in agg else None for s in labels]
        avg_data = [round(agg[s]["avg"], 1) if s in agg else None for s in labels]
        rps_data = [agg[s]["count"] if s in agg else 0 for s in labels]

        p95_datasets.append({
            "label": label,
            "data": p95_data,
            "borderColor": color["line"],
            "backgroundColor": color["fill"],
            "borderWidth": 2,
            "pointRadius": 0,
            "tension": 0.3,
            "fill": False,
            "spanGaps": True,
        })
        avg_datasets.append({
            "label": label,
            "data": avg_data,
            "borderColor": color["line"],
            "backgroundColor": color["fill"],
            "borderWidth": 2,
            "pointRadius": 0,
            "tension": 0.3,
            "fill": False,
            "spanGaps": True,
        })
        rps_datasets.append({
            "label": label,
            "data": rps_data,
            "borderColor": color["line"],
            "backgroundColor": color["fill"],
            "borderWidth": 2,
            "pointRadius": 0,
            "tension": 0.3,
            "fill": True,
            "spanGaps": True,
        })

    html = f"""<!DOCTYPE html>
<html>
<head>
  <title>ActiveMQ Migration - Performance Comparison</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0"></script>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 20px; background: #1a1a2e; color: #e0e0e0; }}
    h1 {{ color: #e0e0e0; text-align: center; }}
    h2 {{ color: #c0c0c0; margin-top: 40px; }}
    .chart-container {{ position: relative; height: 350px; margin: 20px 0; background: #16213e; border-radius: 8px; padding: 15px; }}
    .summary {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 15px; margin: 20px 0; }}
    .card {{ background: #16213e; border-radius: 8px; padding: 15px; text-align: center; }}
    .card h3 {{ margin: 0 0 10px 0; font-size: 14px; color: #888; }}
    .card .value {{ font-size: 28px; font-weight: bold; }}
    .card .sub {{ font-size: 12px; color: #666; margin-top: 5px; }}
    .note {{ background: #16213e; border-left: 3px solid #555; padding: 10px 15px; margin: 20px 0; border-radius: 0 8px 8px 0; font-size: 13px; color: #999; }}
    .classic-kahadb {{ color: rgba(54, 162, 235, 1); }}
    .classic-jdbc {{ color: rgba(255, 159, 64, 1); }}
    .artemis-openwire {{ color: rgba(75, 192, 192, 1); }}
    .artemis-native {{ color: rgba(255, 99, 132, 1); }}
  </style>
</head>
<body>
  <h1>ActiveMQ Migration - Performance Comparison</h1>
  <p style="text-align:center;color:#888">Max throughput test: ramping 100 &rarr; 2000 msg/sec (all 4 paths in parallel) | {datetime.now().strftime('%Y-%m-%d %H:%M')}</p>

  <div class="summary">
"""

    # Summary cards
    for name in ["classic_kahadb", "classic_jdbc", "artemis_openwire", "artemis_native"]:
        if name not in datasets:
            continue
        d = datasets[name]
        agg = d["agg"]
        all_vals = []
        for v in agg.values():
            all_vals.extend([v["p95"]])
        total_reqs = sum(v["count"] for v in agg.values())
        overall_p95 = round(percentile(sorted(all_vals), 95), 1) if all_vals else 0
        overall_avg = round(sum(v["avg"] * v["count"] for v in agg.values()) / max(total_reqs, 1), 1)
        peak_rps = max((v["count"] for v in agg.values()), default=0)
        css_class = name.replace("_", "-")

        html += f"""    <div class="card">
      <h3>{LABELS.get(name, name)}</h3>
      <div class="value {css_class}">{overall_avg}ms</div>
      <div class="sub">avg latency | p95: {overall_p95}ms | peak: {peak_rps} req/s | total: {total_reqs:,}</div>
    </div>
"""

    html += f"""  </div>

  <h2>p95 Latency Over Time (ms)</h2>
  <div class="chart-container"><canvas id="p95Chart"></canvas></div>

  <h2>Average Latency Over Time (ms)</h2>
  <div class="chart-container"><canvas id="avgChart"></canvas></div>

  <h2>Requests Per Second</h2>
  <div class="chart-container"><canvas id="rpsChart"></canvas></div>

  <div class="note">
    <strong>Test config:</strong> ramping-arrival-rate executor, all 4 paths in parallel, 100&rarr;2000 msg/sec over 60s.
    Each request = HTTP POST &rarr; JMS produce (fire-and-forget). Produce-only endpoint.
    Broker tuning applied (journal, memory, connection pool). Docker Desktop on Mac (NIO mode).
  </div>

  <script>
    const labels = {json.dumps(labels)};
    const chartOpts = {{
      responsive: true,
      maintainAspectRatio: false,
      interaction: {{ mode: 'index', intersect: false }},
      plugins: {{
        legend: {{ labels: {{ color: '#ccc' }} }},
        tooltip: {{ mode: 'index', intersect: false }}
      }},
      scales: {{
        x: {{
          title: {{ display: true, text: 'Time (seconds)', color: '#888' }},
          ticks: {{ color: '#888' }},
          grid: {{ color: 'rgba(255,255,255,0.05)' }}
        }},
        y: {{
          title: {{ display: true, text: 'Latency (ms)', color: '#888' }},
          ticks: {{ color: '#888' }},
          grid: {{ color: 'rgba(255,255,255,0.05)' }}
        }}
      }}
    }};

    new Chart(document.getElementById('p95Chart'), {{
      type: 'line',
      data: {{ labels, datasets: {json.dumps(p95_datasets)} }},
      options: chartOpts
    }});

    new Chart(document.getElementById('avgChart'), {{
      type: 'line',
      data: {{ labels, datasets: {json.dumps(avg_datasets)} }},
      options: chartOpts
    }});

    const rpsOpts = JSON.parse(JSON.stringify(chartOpts));
    rpsOpts.scales.y.title.text = 'Requests/sec';
    new Chart(document.getElementById('rpsChart'), {{
      type: 'line',
      data: {{ labels, datasets: {json.dumps(rps_datasets)} }},
      options: rpsOpts
    }});
  </script>
</body>
</html>"""

    with open(output_path, "w") as f:
        f.write(html)
    print(f"Chart written to {output_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 generate-chart.py /tmp/k6-classic_kahadb.json ...")
        sys.exit(1)

    datasets = {}
    for filepath in sys.argv[1:]:
        # Extract target name from filename: k6-classic_kahadb.json -> classic_kahadb
        basename = os.path.basename(filepath)
        name = basename.replace("k6-", "").replace("max-", "").replace(".json", "")
        name = name.replace("-", "_")

        print(f"Parsing {filepath} ({name})...")
        durations, vus, min_time = parse_k6_json(filepath)
        agg = aggregate_buckets(durations)
        datasets[name] = {"agg": agg, "vus": vus}
        total = sum(v["count"] for v in agg.values())
        print(f"  {total:,} data points across {len(agg)} seconds")

    output = os.path.join(os.path.dirname(sys.argv[1]) or "/tmp", "performance-chart.html")
    # Put it in the test results dir instead
    output = "/Users/cedwards/Projects/queue/test/results/performance-chart.html"
    generate_html(datasets, output)


if __name__ == "__main__":
    main()
