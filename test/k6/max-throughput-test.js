// Max throughput test — finds the ceiling before failures start
// Ramps aggressively: 100 → 250 → 500 → 750 → 1000 → 1500 → 2000 msg/sec
// Produce-only endpoint, single path at a time
//
// Usage: TARGET=classic_kahadb k6 run max-throughput-test.js

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
const successRate = new Rate("success_rate");

export const options = {
  scenarios: {
    ramp: {
      executor: "ramping-arrival-rate",
      startRate: 100,
      timeUnit: "1s",
      preAllocatedVUs: 200,
      maxVUs: 500,
      stages: [
        { duration: "10s", target: 250 },
        { duration: "10s", target: 500 },
        { duration: "10s", target: 750 },
        { duration: "10s", target: 1000 },
        { duration: "10s", target: 1500 },
        { duration: "10s", target: 2000 },
      ],
    },
  },
  thresholds: {
    success_rate: ["rate>0.95"],
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
      if (d !== undefined) appDuration.add(d);
    } catch (e) {}
  }
}
