// Throughput test — measures sustained message rate through REST endpoints
// Compares: Classic KahaDB vs Classic JDBC/PostgreSQL vs Artemis OpenWire vs Artemis native
//
// Usage: k6 run throughput-test.js
//   or: docker compose --profile k6 run --rm k6 run /scripts/throughput-test.js

import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

const MONOLITH_CLASSIC = __ENV.MONOLITH_CLASSIC_URL || "http://localhost:8081";
const MONOLITH_CLASSIC_JDBC = __ENV.MONOLITH_CLASSIC_JDBC_URL || "http://localhost:8084";
const MONOLITH_ARTEMIS = __ENV.MONOLITH_ARTEMIS_URL || "http://localhost:8083";
const MICROSERVICE_ARTEMIS = __ENV.MICROSERVICE_ARTEMIS_URL || "http://localhost:8082";

// Custom metrics per target
const classicPassed = new Counter("classic_kahadb_tests_passed");
const classicJdbcPassed = new Counter("classic_jdbc_tests_passed");
const artemisMPassed = new Counter("artemis_openwire_tests_passed");
const artemisNPassed = new Counter("artemis_native_tests_passed");

const classicDuration = new Trend("classic_kahadb_duration_ms");
const classicJdbcDuration = new Trend("classic_jdbc_duration_ms");
const artemisMDuration = new Trend("artemis_openwire_duration_ms");
const artemisNDuration = new Trend("artemis_native_duration_ms");

export const options = {
  scenarios: {
    classic_kahadb: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 20,
      stages: [
        { duration: "10s", target: 10 },
        { duration: "10s", target: 25 },
        { duration: "10s", target: 50 },
        { duration: "30s", target: 50 },
        { duration: "10s", target: 0 },
      ],
      exec: "classicKahadb",
    },
    classic_jdbc: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 20,
      stages: [
        { duration: "10s", target: 10 },
        { duration: "10s", target: 25 },
        { duration: "10s", target: 50 },
        { duration: "30s", target: 50 },
        { duration: "10s", target: 0 },
      ],
      exec: "classicJdbc",
    },
    artemis_openwire: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 20,
      stages: [
        { duration: "10s", target: 10 },
        { duration: "10s", target: 25 },
        { duration: "10s", target: 50 },
        { duration: "30s", target: 50 },
        { duration: "10s", target: 0 },
      ],
      exec: "artemisOpenwire",
    },
    artemis_native: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 20,
      stages: [
        { duration: "10s", target: 10 },
        { duration: "10s", target: 25 },
        { duration: "10s", target: 50 },
        { duration: "30s", target: 50 },
        { duration: "10s", target: 0 },
      ],
      exec: "artemisNative",
    },
  },
  thresholds: {
    checks: ["rate>0.90"],
    classic_kahadb_duration_ms: ["p(95)<10000"],
    classic_jdbc_duration_ms: ["p(95)<10000"],
    artemis_openwire_duration_ms: ["p(95)<10000"],
    artemis_native_duration_ms: ["p(95)<10000"],
  },
};

export function classicKahadb() {
  let r = http.post(`${MONOLITH_CLASSIC}/test/produce`);
  let ok = check(r, {
    "status 200": (r) => r.status === 200,
    "produced": (r) => r.json().produced === true,
  });
  if (ok) classicPassed.add(1);
  if (r.status === 200 && r.json().durationMs) {
    classicDuration.add(r.json().durationMs);
  }
}

export function classicJdbc() {
  let r = http.post(`${MONOLITH_CLASSIC_JDBC}/test/produce`);
  let ok = check(r, {
    "status 200": (r) => r.status === 200,
    "produced": (r) => r.json().produced === true,
  });
  if (ok) classicJdbcPassed.add(1);
  if (r.status === 200 && r.json().durationMs) {
    classicJdbcDuration.add(r.json().durationMs);
  }
}

export function artemisOpenwire() {
  let r = http.post(`${MONOLITH_ARTEMIS}/test/produce`);
  let ok = check(r, {
    "status 200": (r) => r.status === 200,
    "produced": (r) => r.json().produced === true,
  });
  if (ok) artemisMPassed.add(1);
  if (r.status === 200 && r.json().durationMs) {
    artemisMDuration.add(r.json().durationMs);
  }
}

export function artemisNative() {
  let r = http.post(`${MICROSERVICE_ARTEMIS}/test/produce`);
  let ok = check(r, {
    "status 200": (r) => r.status === 200,
    "produced": (r) => r.json().produced === true,
  });
  if (ok) artemisNPassed.add(1);
  if (r.status === 200 && r.json().durationMs) {
    artemisNDuration.add(r.json().durationMs);
  }
}
