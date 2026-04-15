import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');
const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';

export const options = {
  scenarios: {
    autoscale: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 100,
      stages: [
        { target: 10, duration: '1m' },
        { target: 200, duration: '2m' },
        { target: 200, duration: '5m' },
        { target: 10, duration: '2m' },
        { target: 10, duration: '5m' },
      ],
    },
  },
  thresholds: {
    'errors': ['rate<0.05'],
  },
};

export default function () {
  const payload = JSON.stringify({
    id: `scale-${Date.now()}-${__VU}`,
    data: 'x'.repeat(1024),
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
}
