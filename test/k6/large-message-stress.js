// Large message stress test — PDF-like payloads through all three paths
// Tests the OpenWire compatibility layer with large BytesMessages
//
// Usage: k6 run large-message-stress.js
//   or: docker compose --profile k6 run --rm k6 run /scripts/large-message-stress.js

import http from "k6/http";
import { check, group } from "k6";
import { Trend } from "k6/metrics";

const MONOLITH_CLASSIC = __ENV.MONOLITH_CLASSIC_URL || "http://localhost:8081";
const MONOLITH_ARTEMIS = __ENV.MONOLITH_ARTEMIS_URL || "http://localhost:8083";
const MICROSERVICE_ARTEMIS = __ENV.MICROSERVICE_ARTEMIS_URL || "http://localhost:8082";

const classicLargeDuration = new Trend("classic_large_msg_duration_ms");
const artemisLargeDuration = new Trend("artemis_large_msg_duration_ms");
const nativeLargeDuration = new Trend("native_large_msg_duration_ms");

export const options = {
  scenarios: {
    // Sequential per target, 1MB messages
    classic_large: {
      executor: "per-vu-iterations",
      vus: 2,
      iterations: 5,
      exec: "classicLargeMessage",
    },
    artemis_monolith_large: {
      executor: "per-vu-iterations",
      vus: 2,
      iterations: 5,
      exec: "artemisMonolithLargeMessage",
      startTime: "0s",
    },
    artemis_native_large: {
      executor: "per-vu-iterations",
      vus: 2,
      iterations: 5,
      exec: "artemisNativeLargeMessage",
      startTime: "0s",
    },
  },
  thresholds: {
    "checks": ["rate>0.90"],
  },
};

export function classicLargeMessage() {
  let r = http.post(`${MONOLITH_CLASSIC}/test/large-message?sizeMb=1`, null, {
    timeout: "60s",
  });
  let ok = check(r, {
    "status 200": (r) => r.status === 200,
    "all sizes passed": (r) => {
      if (r.status !== 200) return false;
      let results = r.json();
      if (!Array.isArray(results)) return results.passed === true;
      return results.every((t) => t.passed === true);
    },
  });
  if (r.status === 200) {
    let results = r.json();
    if (Array.isArray(results)) {
      results.forEach((t) => classicLargeDuration.add(t.durationMs || 0));
    } else {
      classicLargeDuration.add(results.durationMs || 0);
    }
  }
}

export function artemisMonolithLargeMessage() {
  let r = http.post(`${MONOLITH_ARTEMIS}/test/large-message?sizeMb=1`, null, {
    timeout: "60s",
  });
  let ok = check(r, {
    "status 200": (r) => r.status === 200,
    "all sizes passed": (r) => {
      if (r.status !== 200) return false;
      let results = r.json();
      if (!Array.isArray(results)) return results.passed === true;
      return results.every((t) => t.passed === true);
    },
  });
  if (r.status === 200) {
    let results = r.json();
    if (Array.isArray(results)) {
      results.forEach((t) => artemisLargeDuration.add(t.durationMs || 0));
    } else {
      artemisLargeDuration.add(results.durationMs || 0);
    }
  }
}

export function artemisNativeLargeMessage() {
  let r = http.post(
    `${MICROSERVICE_ARTEMIS}/test/large-message?sizeMb=1`,
    null,
    { timeout: "60s" }
  );
  let ok = check(r, {
    "status 200": (r) => r.status === 200,
    "all sizes passed": (r) => {
      if (r.status !== 200) return false;
      let results = r.json();
      if (!Array.isArray(results)) return results.passed === true;
      return results.every((t) => t.passed === true);
    },
  });
  if (r.status === 200) {
    let results = r.json();
    if (Array.isArray(results)) {
      results.forEach((t) => nativeLargeDuration.add(t.durationMs || 0));
    } else {
      nativeLargeDuration.add(results.durationMs || 0);
    }
  }
}
