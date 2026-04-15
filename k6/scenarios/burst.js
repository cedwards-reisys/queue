import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const sent = new Counter('messages_sent');
const errorRate = new Rate('errors');

const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';
const TARGET_MSGS = parseInt(__ENV.TARGET_MSGS || '100000');

export const options = {
  scenarios: {
    burst: {
      executor: 'shared-iterations',
      iterations: TARGET_MSGS,
      vus: 50,
      maxDuration: '30m',
    },
  },
  thresholds: {
    'errors': ['rate<0.01'],
  },
};

export default function () {
  const payload = JSON.stringify({
    id: `burst-${__ITER}-${__VU}`,
    data: 'x'.repeat(1024),
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  sent.add(1);
}
