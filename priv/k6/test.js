import http from "k6/http";
import { check, sleep } from "k6";
import { htmlReport } from "https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js";

const BASE_URL = __ENV.BASE_URL || "http://localhost:4000";

export const options = {
  stages: [
    { duration: "2m", target: 250 },
    { duration: "2m", target: 500 },
    { duration: "3m", target: 1000 },
    { duration: "10m", target: 1000 },
    { duration: "2m", target: 0 },
  ],

  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: [
      "p(50)<10",
      "p(95)<50",
      "p(99)<100",
    ],
    iterations: ["count>1000000"],
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

export function handleSummary(data) {
  return {
    "report.html": htmlReport(data),
  };
}
