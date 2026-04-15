// Produce-only throughput test — measures pure producer throughput without consumer blocking
// Ramps 10 → 50 → 100 → 200 → 500 → 1000 msg/sec, sustained at 1000 for 30s
//
// Usage: TARGET=classic_kahadb k6 run --out json=/tmp/k6-produce-classic_kahadb.json produce-throughput-test.js
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

const produceDuration = new Trend("produce_duration_ms");
const successRate = new Rate("success_rate");

export const options = {
  scenarios: {
    ramp: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 200,
      maxVUs: 500,
      stages: [
        { duration: "5s", target: 50 },
        { duration: "5s", target: 100 },
        { duration: "5s", target: 200 },
        { duration: "5s", target: 500 },
        { duration: "5s", target: 1000 },
        { duration: "30s", target: 1000 },
        { duration: "5s", target: 0 },
      ],
    },
  },
  thresholds: {
    success_rate: ["rate>0.90"],
    produce_duration_ms: ["p(95)<5000"],
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

  if (r.status === 200) {
    try {
      let d = r.json().durationMs;
      if (d !== undefined) produceDuration.add(d);
    } catch (e) {}
  }
}
