// Native-engine differential (task 7.1 of add-native-oci-engine).
//
// Runs one pinned Docker CLI workflow against a listener socket whose
// creates stay nested and a socket whose creates run as native containers,
// from the same image, and compares exit codes, output and inspected fields.
// Only the differences recorded in docs/embedding.md are normalised, and each
// normalisation is named in the report.
//
//   OPSMARU_DOCKER_ACCEPTANCE=isolated \
//   OPSMARU_DOCKER_CLI=/absolute/docker \
//   OPSMARU_NESTED_SOCKET=/absolute/nested.sock \
//   OPSMARU_NATIVE_SOCKET=/absolute/native.sock \
//   OPSMARU_DOCKER_TEST_IMAGE=alpine:3.22 \
//   OPSMARU_DIFFERENTIAL_REPORT=/absolute/report.json \
//   node test/acceptance/native_differential.mjs
//
// The image must already be in the nested engine. Bind sources are mapped by
// the host to a directory that holds a `hostname` file on both servers.

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";

const environment = process.env;
if (environment.OPSMARU_DOCKER_ACCEPTANCE !== "isolated") {
  throw new Error("Opt in with OPSMARU_DOCKER_ACCEPTANCE=isolated for disposable fixtures");
}

const absolute = (key) => {
  const value = environment[key] || "";
  assert(isAbsolute(value), `${key} must be an absolute path`);
  return value;
};

const cli = absolute("OPSMARU_DOCKER_CLI");
const sockets = { nested: absolute("OPSMARU_NESTED_SOCKET"), native: absolute("OPSMARU_NATIVE_SOCKET") };
const image = environment.OPSMARU_DOCKER_TEST_IMAGE || "";
assert(image !== "", "OPSMARU_DOCKER_TEST_IMAGE is required");
const reportPath = environment.OPSMARU_DIFFERENTIAL_REPORT;

const config = mkdtempSync(join(tmpdir(), "opsmaru-native-differential-"));
writeFileSync(join(config, "config.json"), "{}");
const tag = `nd${process.pid}`;

function docker(engine, args, { input, timeout = 120_000 } = {}) {
  const result = spawnSync(cli, ["--config", config, "--host", `unix://${sockets[engine]}`, ...args], {
    input: input ?? "",
    timeout,
    encoding: "utf8",
  });
  return { exit: result.status, stdout: result.stdout, stderr: result.stderr };
}

function dockerAsync(engine, args) {
  const child = spawn(cli, ["--config", config, "--host", `unix://${sockets[engine]}`, ...args], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (bytes) => (stdout += bytes));
  child.stderr.on("data", (bytes) => (stderr += bytes));
  const done = new Promise((resolve) => child.on("close", (exit) => resolve({ exit, stdout, stderr })));
  return { child, done };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(engine, name, predicate, timeout = 20_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (predicate(docker(engine, ["logs", name]))) return true;
    await sleep(200);
  }
  return false;
}

function inspect(engine, name) {
  const result = docker(engine, ["inspect", name]);
  assert.equal(result.exit, 0, `${engine} inspect ${name}: ${result.stderr}`);
  return JSON.parse(result.stdout)[0];
}

const pick = (object, paths) =>
  Object.fromEntries(paths.map((path) => [path, path.split(".").reduce((value, key) => value?.[key], object)]));

const timestamp = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{9}Z/g;

// Each case returns a plain object compared across engines.
const cases = {
  async "run: exit code, foreground, --rm"(engine) {
    // Listing covers both engines on either socket, so the count shows removal.
    const count = () => docker(engine, ["ps", "-a", "-q"]).stdout.trim().split("\n").filter(Boolean).length;
    const before = count();
    const run = docker(engine, ["run", "--rm", image, "sh", "-c", "echo out; echo err >&2; exit 3"]);
    return { run, removed: count() === before };
  },

  async "run: foreground with a name, inspect, rm"(engine) {
    const name = `${tag}-fg`;
    const run = docker(engine, ["run", "--name", name, image, "sh", "-c", "echo hello"]);
    const state = pick(inspect(engine, name), ["State.Status", "State.Running", "State.ExitCode", "State.OOMKilled"]);
    const rm = docker(engine, ["rm", name]);
    return { run, state, rm: rm.exit };
  },

  async "detached run, stop with a trapped TERM, rm"(engine) {
    const name = `${tag}-stop`;
    const script = 'trap "echo bye; exit 7" TERM; echo ready; while :; do sleep 0.1; done';
    const run = docker(engine, ["run", "-d", "--name", name, image, "sh", "-c", script]);
    const ready = await until(engine, name, (logs) => logs.stdout.includes("ready"));
    const stop = docker(engine, ["stop", "--timeout", "5", name]);
    const state = pick(inspect(engine, name), ["State.Status", "State.Running", "State.ExitCode"]);
    const logs = docker(engine, ["logs", name]);
    const rm = docker(engine, ["rm", name]);
    return { run: run.exit, ready, stop, state, logs, rm: rm.exit };
  },

  async "kill with a signal, then the default SIGKILL"(engine) {
    const name = `${tag}-kill`;
    const script = 'trap "exit 9" USR1; echo ready; while :; do sleep 0.1; done';
    docker(engine, ["run", "-d", "--name", name, image, "sh", "-c", script]);
    const ready = await until(engine, name, (logs) => logs.stdout.includes("ready"));
    const kill = docker(engine, ["kill", "--signal", "USR1", name]);
    const wait = docker(engine, ["wait", name]);
    const restart = docker(engine, ["start", name]);
    await until(engine, name, (logs) => logs.stdout.split("ready").length > 2);
    const killed = docker(engine, ["kill", name]);
    const waitKilled = docker(engine, ["wait", name]);
    const state = pick(inspect(engine, name), ["State.Status", "State.ExitCode", "RestartCount"]);
    const rm = docker(engine, ["rm", name]);
    return { ready, kill, wait, restart: restart.exit, killed, waitKilled, state, rm: rm.exit };
  },

  async "exec: stdin EOF, named user, cwd and env, exit code"(engine) {
    const name = `${tag}-exec`;
    docker(engine, ["run", "-d", "--name", name, image, "sh", "-c", "echo ready; exec sleep 600"]);
    await until(engine, name, (logs) => logs.stdout.includes("ready"));
    const stdin = docker(engine, ["exec", "-i", name, "sh", "-c", "cat; echo; echo done"], { input: "abc" });
    const user = docker(engine, ["exec", "--user", "nobody", name, "id", "-un"]);
    const setup = docker(engine, ["exec", "-w", "/tmp", "-e", "FOO=bar", name, "sh", "-c", 'pwd; echo "$FOO"']);
    const code = docker(engine, ["exec", name, "sh", "-c", "echo bye >&2; exit 5"]);
    const missing = docker(engine, ["exec", name, "/no/such/binary"]);
    const rm = docker(engine, ["rm", "--force", name]);
    return { stdin, user, setup, code, missing: missing.exit, rm: rm.exit };
  },

  async "logs: timestamps, tail and follow"(engine) {
    const name = `${tag}-logs`;
    const script =
      // stdout and stderr are separate pipes in both engines, so neither
      // orders writes across them that land together. The pauses keep the
      // order this case checks deterministic.
      'trap "echo stopping; exit 0" TERM; for i in 1 2 3 4 5; do echo line $i; done; sleep 0.3; ' +
      'echo warn >&2; sleep 0.3; echo ready; while :; do sleep 0.1; done';
    docker(engine, ["run", "-d", "--name", name, image, "sh", "-c", script]);
    await until(engine, name, (logs) => logs.stdout.includes("ready"));
    const all = docker(engine, ["logs", name]);
    const tail = docker(engine, ["logs", "--tail", "2", name]);
    const stamped = docker(engine, ["logs", "--timestamps", "--tail", "3", name]);
    const stampsValid = stamped.stdout.trim().split("\n").every((line) => /^\S+Z /.test(line));
    const follow = dockerAsync(engine, ["logs", "--follow", name]);
    await sleep(1_000);
    const stop = docker(engine, ["stop", "--timeout", "5", name]);
    const followed = await Promise.race([follow.done, sleep(20_000).then(() => ({ exit: "timeout" }))]);
    if (followed.exit === "timeout") follow.child.kill();
    const rm = docker(engine, ["rm", name]);
    return {
      all,
      tail,
      stamped: {
        ...stamped,
        stdout: stamped.stdout.replace(timestamp, "<timestamp>"),
        stderr: stamped.stderr.replace(timestamp, "<timestamp>"),
      },
      stampsValid,
      stop: stop.exit,
      followed,
      rm: rm.exit,
    };
  },

  async "create fields, limits and a bind mount, start, rename"(engine) {
    const name = `${tag}-fields`;
    const create = docker(engine, [
      "create", "--name", name,
      "--env", "A=1", "--label", "acceptance=native", "--workdir", "/tmp", "--hostname", "fixture-host",
      "--user", "nobody", "--memory", "64m", "--cpus", "0.5", "--pids-limit", "50",
      "--volume", "/fixture:/mnt:ro", "--entrypoint", "/bin/sh", image, "-c", "echo ready; exec sleep 600",
    ]);
    const created = inspect(engine, name);
    const fields = pick(created, [
      "Config.Env", "Config.Labels", "Config.WorkingDir", "Config.Hostname", "Config.User",
      "Config.Entrypoint", "Config.Cmd", "Config.Image", "Config.Tty", "Config.OpenStdin",
      "HostConfig.Memory", "HostConfig.NanoCpus", "HostConfig.PidsLimit", "HostConfig.Binds",
      "HostConfig.AutoRemove", "HostConfig.RestartPolicy", "State.Status", "Name", "Path", "Args",
    ]);
    fields.Mounts = (created.Mounts || []).map((mount) => pick(mount, ["Type", "Source", "Destination", "RW", "Mode", "Propagation"]));
    const start = docker(engine, ["start", name]);
    await until(engine, name, (logs) => logs.stdout.includes("ready"));
    const inside = docker(engine, [
      "exec", name, "sh", "-c",
      'id -un; hostname; pwd; echo "A=$A"; test -f /mnt/hostname && echo bound; touch /mnt/x 2>&1; ' +
        "cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max /sys/fs/cgroup/cpu.max",
    ]);
    const rename = docker(engine, ["rename", name, `${name}-renamed`]);
    const renamed = pick(inspect(engine, `${name}-renamed`), ["Name", "State.Running"]);
    const rm = docker(engine, ["rm", "--force", `${name}-renamed`]);
    return { create: create.exit, fields, start: start.exit, inside, rename: rename.exit, renamed, rm: rm.exit };
  },
};

// Differences recorded in docs/embedding.md, applied to both engines' results.
const normalisations = [
  {
    name: "container IDs and generated names",
    apply: (text) => text.replace(/\b[0-9a-f]{64}\b/g, "<id>").replace(/\boc-[0-9a-f]{12}\b/g, "<instance>"),
  },
  { name: "run-scoped names", apply: (text) => text.replaceAll(tag, "<tag>") },
];

function normalise(value) {
  let text = JSON.stringify(value);
  for (const { apply } of normalisations) text = apply(text);
  return JSON.parse(text);
}

function differences(left, right, path = "") {
  if (JSON.stringify(left) === JSON.stringify(right)) return [];
  if (left && right && typeof left === "object" && typeof right === "object" && !Array.isArray(left)) {
    return [...new Set([...Object.keys(left), ...Object.keys(right)])].flatMap((key) =>
      differences(left[key], right[key], path ? `${path}.${key}` : key),
    );
  }
  return [{ path, nested: left, native: right }];
}

const report = { image, tag, normalisations: normalisations.map(({ name }) => name), cases: [] };
let failed = 0;

try {
  const only = environment.OPSMARU_DIFFERENTIAL_ONLY;
  const repeat = Number(environment.OPSMARU_DIFFERENTIAL_REPEAT || "1");
  const selected = Object.entries(cases).filter(([name]) => !only || name.includes(only));
  for (const [name, run] of selected.flatMap((entry) => Array(repeat).fill(entry))) {
    const results = {};
    for (const engine of ["nested", "native"]) {
      const started = Date.now();
      results[engine] = normalise(await run(engine));
      results[`${engine}_ms`] = Date.now() - started;
    }
    const diff = differences(results.nested, results.native);
    report.cases.push({ name, passed: diff.length === 0, differences: diff, ...results });
    if (diff.length === 0) console.log(`Passed ${name}`);
    else {
      failed += 1;
      console.log(`Differs ${name}`);
      for (const d of diff) console.log(`  ${d.path}: nested=${JSON.stringify(d.nested)} native=${JSON.stringify(d.native)}`);
    }
  }
} finally {
  for (const engine of ["nested", "native"]) {
    for (const suffix of ["fg", "stop", "kill", "exec", "logs", "fields", "fields-renamed"]) {
      docker(engine, ["rm", "--force", `${tag}-${suffix}`]);
    }
  }
  rmSync(config, { recursive: true, force: true });
  if (reportPath) writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
}

process.exitCode = failed === 0 ? 0 : 1;
