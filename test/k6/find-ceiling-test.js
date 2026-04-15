// Find-ceiling test — gradually ramp until drops start
// Slower ramp than max-throughput to find the sustainable rate
// Ramps: 10 → 50 → 100 → 200 → 300 → 400 → 500 msg/sec
// Higher VU pool (2000) to avoid artificial VU exhaustion
//
// Usage: TARGET=artemis_native k6 run find-ceiling-test.js

import http from "k6/http";
import { check } from "k6";
import { Trend, Rate } from "k6/metrics";

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
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 100,
      maxVUs: 2000,
      stages: [
        { duration: "10s", target: 50 },
        { duration: "15s", target: 100 },
        { duration: "15s", target: 200 },
        { duration: "15s", target: 300 },
        { duration: "15s", target: 400 },
        { duration: "15s", target: 500 },
        { duration: "15s", target: 500 },  // hold at 500
      ],
    },
  },
  thresholds: {
    success_rate: ["rate>0.99"],
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
