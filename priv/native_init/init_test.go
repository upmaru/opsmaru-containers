package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// TestMain lets exec-mode tests run runExec in a child copy of the test
// binary, because runExec replaces its process.
func TestMain(m *testing.M) {
	if args := os.Getenv("NATIVE_INIT_TEST_EXEC"); args != "" {
		var argv []string
		if err := json.Unmarshal([]byte(args), &argv); err != nil {
			os.Exit(99)
		}
		root := os.Getenv("NATIVE_INIT_TEST_ROOT")
		os.Exit(runExec(testPaths(root), argv))
	}
	os.Exit(m.Run())
}

func testPaths(root string) Paths {
	return Paths{
		Spec:         filepath.Join(root, ".opsmaru/spec.json"),
		State:        filepath.Join(root, ".opsmaru/state"),
		Run:          filepath.Join(root, ".opsmaru/state/run.json"),
		Control:      filepath.Join(root, ".opsmaru/state/control.sock"),
		Logs:         filepath.Join(root, ".opsmaru/logs"),
		Root:         root,
		CgroupEvents: filepath.Join(root, "memory.events"),
	}
}

// shortRoot keeps the control socket path under the Unix socket length limit.
func shortRoot(t *testing.T) string {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "oci")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	return root
}

func writeSpec(t *testing.T, root string, spec map[string]any) {
	t.Helper()
	spec["version"] = 1
	if _, ok := spec["user"]; !ok {
		spec["user"] = fmt.Sprintf("%d:%d", os.Geteuid(), os.Getegid())
	}
	data, err := json.Marshal(spec)
	if err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(root, ".opsmaru/spec.json"), string(data))
}

func output(t *testing.T, root string) (stdout, stderr string, runs []uint32) {
	t.Helper()
	for _, record := range readAll(t, filepath.Join(root, ".opsmaru/logs")) {
		if record.Stream == streamStdout {
			stdout += string(record.Data)
		} else {
			stderr += string(record.Data)
		}
		if len(runs) == 0 || runs[len(runs)-1] != record.Run {
			runs = append(runs, record.Run)
		}
	}
	return
}

func TestInitRecordsExitAndSeparateStreams(t *testing.T) {
	root := shortRoot(t)
	writeSpec(t, root, map[string]any{
		"argv": []string{"/bin/sh", "-c", "echo out; echo err >&2; printf partial; exit 3"},
		"env":  []string{"PATH=/usr/bin:/bin"},
	})
	if code := runInit(testPaths(root), hostSystem{}); code != 3 {
		t.Fatalf("exit %d", code)
	}
	record, err := readRun(filepath.Join(root, ".opsmaru/state/run.json"))
	if err != nil || record.Run != 1 || *record.ExitCode != 3 || record.Signal != nil || record.FinishedAt == nil || record.Pid == 0 {
		t.Fatalf("%+v %v", record, err)
	}
	stdout, stderr, _ := output(t, root)
	if stdout != "out\npartial" || stderr != "err\n" {
		t.Fatalf("stdout %q stderr %q", stdout, stderr)
	}

	// A restart is the next run and appends to the same logs.
	writeSpec(t, root, map[string]any{"argv": []string{"/bin/echo", "second"}})
	if code := runInit(testPaths(root), hostSystem{}); code != 0 {
		t.Fatalf("second exit %d", code)
	}
	stdout, _, runs := output(t, root)
	if stdout != "out\npartialsecond\n" || !slices.Equal(runs, []uint32{1, 2}) {
		t.Fatalf("stdout %q runs %v", stdout, runs)
	}
}

func TestInitCarriesArgvExactly(t *testing.T) {
	root := shortRoot(t)
	args := []string{"$HOME", "a b", `x\y`, "*", "", "line\nbreak", "'q'", "|[~]", "héllo ✓"}
	writeSpec(t, root, map[string]any{
		"argv": append([]string{"/bin/sh", "-c", `printf '%s|' "$@"`, "sh"}, args...),
	})
	if code := runInit(testPaths(root), hostSystem{}); code != 0 {
		t.Fatalf("exit %d", code)
	}
	stdout, _, _ := output(t, root)
	if want := strings.Join(args, "|") + "|"; stdout != want {
		t.Fatalf("got %q want %q", stdout, want)
	}
}

func TestInitStartFailures(t *testing.T) {
	cases := map[string]struct {
		argv []string
		user string
		code int
		text string
	}{
		"missing":        {[]string{"no-such-command"}, "", 127, `"no-such-command": executable file not found in $PATH`},
		"missing path":   {[]string{"/no/such/file"}, "", 127, "no such file"},
		"not executable": {[]string{"/etc/hosts"}, "", 126, "permission denied"},
		"unknown user":   {[]string{"/bin/true"}, "nobody-here", 128, "unable to find user nobody-here"},
		"missing cwd":    {[]string{"/bin/true"}, "", 127, `chdir to cwd ("/no/such/dir") set in config.json failed`},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			root := shortRoot(t)
			spec := map[string]any{"argv": c.argv}
			if name == "missing cwd" {
				spec["cwd"] = "/no/such/dir"
			}
			if c.user != "" {
				spec["user"] = c.user
			}
			writeSpec(t, root, spec)
			if code := runInit(testPaths(root), hostSystem{}); code != c.code {
				t.Fatalf("exit %d", code)
			}
			record, err := readRun(filepath.Join(root, ".opsmaru/state/run.json"))
			if err != nil || *record.ExitCode != c.code || record.Error == nil || !strings.Contains(*record.Error, c.text) || record.Pid != 0 {
				t.Fatalf("%+v %v", record, err)
			}
		})
	}
}

func TestInitKillAndStop(t *testing.T) {
	cases := map[string]struct {
		script  string
		request controlRequest
		code    int
		signal  string
	}{
		"kill default term": {"exec sleep 30", controlRequest{Op: "kill", Signal: "TERM"}, 143, "SIGTERM"},
		"kill hup trapped":  {"trap 'echo hup; exit 4' HUP; while :; do sleep 0.05; done", controlRequest{Op: "kill", Signal: "SIGHUP"}, 4, ""},
		"stop after timeout": {"trap '' TERM; while :; do sleep 0.05; done",
			controlRequest{Op: "stop", Timeout: ptr(1)}, 137, "SIGKILL"},
		"stop with signal": {"exec sleep 30", controlRequest{Op: "stop", Signal: "INT", Timeout: ptr(5)}, 130, "SIGINT"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			root := shortRoot(t)
			writeSpec(t, root, map[string]any{"argv": []string{"/bin/sh", "-c", c.script}})
			paths := testPaths(root)
			done := make(chan int, 1)
			start := time.Now()
			go func() { done <- runInit(paths, hostSystem{}) }()
			waitFor(t, func() bool { _, err := os.Stat(paths.Control); return err == nil })
			time.Sleep(200 * time.Millisecond)
			if err := callControl(paths.Control, c.request); err != nil {
				t.Fatal(err)
			}
			select {
			case code := <-done:
				if code != c.code {
					t.Fatalf("exit %d", code)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("init did not exit")
			}
			if c.request.Op == "stop" && c.request.Timeout != nil && *c.request.Timeout == 1 && time.Since(start) < time.Second {
				t.Fatal("killed before the stop timeout")
			}
			record, _ := readRun(paths.Run)
			if *record.ExitCode != c.code || (c.signal == "" && record.Signal != nil) || (c.signal != "" && (record.Signal == nil || *record.Signal != c.signal)) {
				t.Fatalf("%+v", record)
			}
			if err := callControl(paths.Control, controlRequest{Op: "kill", Signal: "KILL"}); err == nil {
				t.Fatal("control answered after exit")
			}
		})
	}
}

func TestInitRecordsOOMKills(t *testing.T) {
	root := shortRoot(t)
	events := filepath.Join(root, "memory.events")
	mustWrite(t, events, "oom_kill 0\n")
	writeSpec(t, root, map[string]any{"argv": []string{"/bin/sh", "-c", "printf 'oom_kill 1\\n' > " + events + "; kill -9 $$"}})
	if code := runInit(testPaths(root), hostSystem{}); code != 137 {
		t.Fatalf("exit %d", code)
	}
	if record, _ := readRun(filepath.Join(root, ".opsmaru/state/run.json")); !record.OOMKilled {
		t.Fatalf("%+v", record)
	}
}

func TestExecModeEnvironmentAndFailures(t *testing.T) {
	root := shortRoot(t)
	writeSpec(t, root, map[string]any{
		"argv":     []string{"/bin/true"},
		"env":      []string{"PATH=/usr/bin:/bin", "IMAGE=1", "DROP=x"},
		"hostname": "abc123",
		"cwd":      "/tmp",
	})

	run := func(argv []string, env ...string) (string, int) {
		data, _ := json.Marshal(argv)
		cmd := exec.Command(os.Args[0])
		cmd.Env = append([]string{"NATIVE_INIT_TEST_EXEC=" + string(data), "NATIVE_INIT_TEST_ROOT=" + root,
			"HOME=/incus-home", "USER=incus", "LANG=C.UTF-8"}, env...)
		out, err := cmd.CombinedOutput()
		code := 0
		if exit, ok := err.(*exec.ExitError); ok {
			code = exit.ExitCode()
		}
		return string(out), code
	}

	out, code := run([]string{"--", "/usr/bin/env"}, "A=1", "B=two words", `OPSMARU_EXEC_ENV=["A","B"]`, `OPSMARU_EXEC_UNSET=["DROP"]`)
	lines := strings.Split(strings.TrimSpace(out), "\n")
	want := []string{"PATH=/usr/bin:/bin", "HOSTNAME=abc123", "IMAGE=1", "A=1", "B=two words", "HOME=/"}
	if code != 0 || !slices.Equal(lines, want) {
		t.Fatalf("code %d env %q want %q", code, lines, want)
	}
	out, code = run([]string{"--", "/bin/pwd"})
	if code != 0 || strings.TrimSpace(out) != "/tmp" && strings.TrimSpace(out) != "/private/tmp" {
		t.Fatalf("pwd %q %d", out, code)
	}
	out, code = run([]string{"--cwd", "/", "--", "sh", "-c", "pwd; exit 7"})
	if code != 7 || strings.TrimSpace(out) != "/" {
		t.Fatalf("cwd flag %q %d", out, code)
	}
	if out, code = run([]string{"--", "no-such-command"}); code != 127 || !strings.Contains(out, "executable file not found") {
		t.Fatalf("missing %q %d", out, code)
	}
	if _, code = run([]string{"--cwd", "/no/such/dir", "--", "/bin/true"}); code != 127 {
		t.Fatalf("missing cwd %d", code)
	}
	if _, code = run([]string{"--user", "nobody-here", "--", "/bin/true"}); code != 128 {
		t.Fatalf("unknown user %d", code)
	}
}

func waitFor(t *testing.T, ready func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ready() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
