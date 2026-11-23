import assert from "node:assert/strict";
import { request } from "node:http";
import { isAbsolute } from "node:path";

const environment = process.env;
if (environment.OPSMARU_DOCKER_ACCEPTANCE !== "isolated") {
  throw new Error("Opt in with OPSMARU_DOCKER_ACCEPTANCE=isolated for disposable fixtures");
}

const direct = socketPath("OPSMARU_DOCKER_DIRECT_SOCKET");
const relay = socketPath("OPSMARU_DOCKER_RELAY_SOCKET");
assert.notEqual(direct, relay, "Use separately supplied direct and relayed endpoints");

const scopedPaths = [
  ["HEAD", "/_ping"],
  ["GET", "/v1.57/containers/json?all=true"],
  ["GET", "/v1.57/images/json"],
  ["GET", "/v1.57/volumes"],
  ["GET", "/v1.57/networks"],
];

const version = await get(direct, "GET", "/version");
assert.equal(version.status, 200);
assert.equal(version.body.Version, "29.10.0");
assert.equal(version.body.ApiVersion, "1.57");
assert.deepEqual(await get(relay, "GET", "/version"), version, "GET /version");

for (const [method, path] of scopedPaths) {
  const expected = await get(direct, method, path);
  assert.equal(expected.status, 200, `${method} ${path} direct status`);
  assert.deepEqual(await get(relay, method, path), expected, `${method} ${path}`);
  console.log(`Passed ${method} ${path}`);
}

function socketPath(key) {
  const path = environment[key] || "";
  assert(isAbsolute(path), `${key} must be an explicit absolute socket path`);
  return path;
}

function get(socketPath, method, path) {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, method, path, agent: false }, (res) => {
      const chunks = [];
      let size = 0;
      res.on("data", (bytes) => {
        size += bytes.length;
        if (size > 8 * 1024 * 1024) req.destroy(new Error("Fixture response limit exceeded"));
        else chunks.push(bytes);
      });
      res.on("error", reject);
      res.on("end", () => {
        try {
          const text = Buffer.concat(chunks).toString();
          const headers = ["api-version", "content-type", "docker-experimental", "ostype"]
            .map((name) => [name, res.headers[name]]);
          resolve({ status: res.statusCode, headers, body: text === "" ? null : JSON.parse(text) });
        } catch (error) {
          reject(error);
        }
      });
    });

    req.setTimeout(10_000, () => req.destroy(new Error("Fixture response timeout")));
    req.on("error", reject);
    req.end();
  });
}
