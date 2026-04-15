// Solo throughput test — runs ONE path at a time for clean performance graphs
// Ramps 10 → 25 → 50 → 100 → 150 msg/sec, sustained at 150 for 30s
// Capped at 150/sec to stay within Docker Desktop's networking limits
//
// Usage: TARGET=classic_kahadb k6 run --out json=/tmp/k6-classic_kahadb.json solo-throughput-test.js
//
// Valid TARGETs: classic_kahadb, classic_jdbc, artemis_openwire, artemis_native

import http from "k6/http";
import { check } from "k6";
import { Trend, Counter, Rate } from "k6/metrics";

const TARGET = __ENV.TARGET || "classic_kahadb";

const URLS = {
  classic_kahadb: "http://localhost:8081/test/produce",
  classic_jdbc: "http://localhost:8084/test/produce",
  artemis_openwire: "http://localhost:8083/test/produce",
  artemis_native: "http://localhost:8082/test/produce",
};

const URL = URLS[TARGET];
if (!URL) {
  throw new Error(`Unknown TARGET: ${TARGET}. Use one of: ${Object.keys(URLS).join(", ")}`);
}

const appDuration = new Trend("app_duration_ms");
const testsPassed = new Counter("tests_passed");
const successRate = new Rate("success_rate");

export const options = {
  scenarios: {
    ramp: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 50,
      maxVUs: 100,
      stages: [
        { duration: "10s", target: 25 },
        { duration: "10s", target: 50 },
        { duration: "10s", target: 100 },
        { duration: "10s", target: 150 },
        { duration: "30s", target: 150 },
        { duration: "10s", target: 0 },
      ],
    },
  },
  thresholds: {
    success_rate: ["rate>0.90"],
    app_duration_ms: ["p(95)<15000"],
  },
};

export default function () {
  let r = http.post(URL);
  let ok = check(r, {
    "status 200": (r) => r.status === 200,
    "produced": (r) => {
      try { return r.json().produced === true; } catch (e) { return false; }
    },
  });

  successRate.add(ok ? 1 : 0);
  if (ok) testsPassed.add(1);

  if (r.status === 200) {
    try {
      let d = r.json().durationMs;
      if (d !== undefined) appDuration.add(d);
    } catch (e) {}
  }
}
