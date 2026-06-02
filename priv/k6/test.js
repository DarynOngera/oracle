import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:4000";
const RATE = parseInt(__ENV.RATE || "500");
const DURATION = __ENV.DURATION || "5m";
const PRE_ALLOCATED_VUS = parseInt(__ENV.PRE_ALLOCATED_VUS || "100");
const MAX_VUS = parseInt(__ENV.MAX_VUS || "1000");

export const options = {
  scenarios: {
    search_sustained_load: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,
    },
  },

  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: [
      "p(50)<10",
      "p(95)<50",
      "p(99)<100",
    ],
  },
};

const queries = [
  // Exact matches
  "iphone",
  "iphone 15",
  "iphone 15 pro",
  "samsung",
  "galaxy",
  "galaxy ultra",
  "pixel",
  "google pixel",
  "macbook",
  "macbook pro",
  "headphones",
  "airpods",
  "keyboard",
  "mouse",

  // Shop names
  "kilimani",
  "kilimani electronics",
  "westlands",
  "nairobi gadget",
  "digital world",
  "tech plaza",
  "computer solutions",

  // Typos
  "iphne",
  "samsng",
  "galxy",
  "macbok",
  "airpods",
  "kilmani",
  "electornics",
  "gadet",
  "laptp",

  // Prefix searches
  "iph",
  "gal",
  "pix",
  "mac",
  "kil",
  "nai",
  "tec",

  // Multi-token
  "google pixel pro",
  "samsung galaxy ultra",
  "wireless headphones",
  "gaming keyboard",
  "laptop centre nairobi",
];

export default function () {
  const query = queries[Math.floor(Math.random() * queries.length)];
  const url = `${BASE_URL}/api/search?q=${encodeURIComponent(query)}`;

  const res = http.get(url, {
    tags: {
      endpoint: "search",
    },
  });

  check(res, {
    "status is 200": (r) => r.status === 200,
    "response time < 100ms": (r) => r.timings.duration < 100,
    "content-type is JSON": (r) =>
      r.headers["Content-Type"] &&
      r.headers["Content-Type"].includes("application/json"),
  });
}
