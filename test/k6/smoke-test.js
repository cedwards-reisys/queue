// Smoke test — validates all test apps respond and basic message flow works
// Usage: k6 run smoke-test.js

import http from "k6/http";
import { check, group } from "k6";

const MONOLITH_CLASSIC = __ENV.MONOLITH_CLASSIC_URL || "http://localhost:8081";
const MONOLITH_CLASSIC_JDBC = __ENV.MONOLITH_CLASSIC_JDBC_URL || "http://localhost:8084";
const MONOLITH_ARTEMIS = __ENV.MONOLITH_ARTEMIS_URL || "http://localhost:8083";
const MICROSERVICE_ARTEMIS = __ENV.MICROSERVICE_ARTEMIS_URL || "http://localhost:8082";

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    checks: ["rate==1.0"],
  },
};

export default function () {
  group("health checks", function () {
    let r1 = http.get(`${MONOLITH_CLASSIC}/test/health`);
    check(r1, { "classic-kahadb healthy": (r) => r.status === 200 });

    let r2 = http.get(`${MONOLITH_CLASSIC_JDBC}/test/health`);
    check(r2, { "classic-jdbc healthy": (r) => r.status === 200 });

    let r3 = http.get(`${MONOLITH_ARTEMIS}/test/health`);
    check(r3, { "artemis-openwire healthy": (r) => r.status === 200 });

    let r4 = http.get(`${MICROSERVICE_ARTEMIS}/test/health`);
    check(r4, { "artemis-native healthy": (r) => r.status === 200 });
  });

  group("classic-kahadb small message", function () {
    let r = http.post(`${MONOLITH_CLASSIC}/test/small-message`);
    check(r, {
      "status 200": (r) => r.status === 200,
      "test passed": (r) => r.json().passed === true,
    });
  });

  group("classic-jdbc small message", function () {
    let r = http.post(`${MONOLITH_CLASSIC_JDBC}/test/small-message`);
    check(r, {
      "status 200": (r) => r.status === 200,
      "test passed": (r) => r.json().passed === true,
    });
  });

  group("artemis-openwire small message", function () {
    let r = http.post(`${MONOLITH_ARTEMIS}/test/small-message`);
    check(r, {
      "status 200": (r) => r.status === 200,
      "test passed": (r) => r.json().passed === true,
    });
  });

  group("artemis-native small message", function () {
    let r = http.post(`${MICROSERVICE_ARTEMIS}/test/small-message`);
    check(r, {
      "status 200": (r) => r.status === 200,
      "test passed": (r) => r.json().passed === true,
    });
  });
}
