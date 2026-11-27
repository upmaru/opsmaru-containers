package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
)

func TestSpecDefaultsAndValidation(t *testing.T) {
	spec, err := parseSpec([]byte(`{"version":1,"argv":["/bin/true"]}`))
	if err != nil {
		t.Fatal(err)
	}
	if spec.Cwd != "/" || spec.StopSignal != "SIGTERM" || spec.Log.Driver != "local" ||
		spec.Log.MaxSize != defaultLogSize || spec.Log.MaxFiles != defaultLogKeep {
		t.Fatalf("defaults not applied: %+v", spec)
	}

	invalid := map[string]string{
		"version":         `{"version":2,"argv":["x"]}`,
		"empty argv":      `{"version":1,"argv":[]}`,
		"unknown field":   `{"version":1,"argv":["x"],"tty":true}`,
		"relative cwd":    `{"version":1,"argv":["x"],"cwd":"tmp"}`,
		"bad signal":      `{"version":1,"argv":["x"],"stop_signal":"SIGNOPE"}`,
		"bad driver":      `{"version":1,"argv":["x"],"log":{"driver":"syslog"}}`,
		"tiny rotation":   `{"version":1,"argv":["x"],"log":{"max_size":10}}`,
		"env without key": `{"version":1,"argv":["x"],"env":["=x"]}`,
		"trailing":        `{"version":1,"argv":["x"]} {}`,
	}
	for name, input := range invalid {
		if _, err := parseSpec([]byte(input)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}

	path := filepath.Join(t.TempDir(), "spec.json")
	if err := os.WriteFile(path, bytes.Repeat([]byte(" "), specLimit+1), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadSpec(path); err == nil {
		t.Error("oversized spec accepted")
	}
}

func TestRunRecordIsReplacedAtomically(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "run.json")
	if err := writeRun(path, RunRecord{Run: 1, Pid: 5, StartedAt: "a"}); err != nil {
		t.Fatal(err)
	}
	if err := writeRun(path, RunRecord{Run: 1, Pid: 5, StartedAt: "a", FinishedAt: ptr("b"), ExitCode: ptr(3)}); err != nil {
		t.Fatal(err)
	}
	record, err := readRun(path)
	if err != nil || record.Run != 1 || *record.ExitCode != 3 || *record.FinishedAt != "b" || record.Version != 1 {
		t.Fatalf("record %+v err %v", record, err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("temporary files left: %v", entries)
	}
	if err := os.WriteFile(path, []byte("{nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readRun(path); err == nil {
		t.Error("malformed record accepted")
	}
}

func TestIdentityResolution(t *testing.T) {
	root := t.TempDir()
	mustWrite(t, filepath.Join(root, "etc/passwd"), "root:x:0:0:root:/root:/bin/sh\n# comment\nnginx:x:101:101:nginx:/var/cache/nginx:/sbin/nologin\nbroken:x:abc:1::/:/bin/sh\n")
	mustWrite(t, filepath.Join(root, "etc/group"), "root:x:0:\nnginx:x:101:\nwww:x:33:nginx,other\nadm:x:4:nginx\n")

	cases := []struct {
		user     string
		groupAdd []string
		want     Identity
	}{
		{"", nil, Identity{UID: 0, GID: 0, Home: "/root"}},
		{"nginx", nil, Identity{UID: 101, GID: 101, Groups: []uint32{4, 33}, Home: "/var/cache/nginx"}},
		{"101", nil, Identity{UID: 101, GID: 101, Groups: []uint32{4, 33}, Home: "/var/cache/nginx"}},
		{"nginx:www", nil, Identity{UID: 101, GID: 33, Home: "/var/cache/nginx"}},
		{"1234:5678", nil, Identity{UID: 1234, GID: 5678, Home: "/"}},
		{"1234", []string{"adm", "99"}, Identity{UID: 1234, GID: 0, Groups: []uint32{4, 99}, Home: "/"}},
	}
	for _, c := range cases {
		got, err := resolveIdentity(root, c.user, c.groupAdd)
		if err != nil {
			t.Errorf("%q: %v", c.user, err)
			continue
		}
		if got.UID != c.want.UID || got.GID != c.want.GID || got.Home != c.want.Home || !slices.Equal(got.Groups, c.want.Groups) {
			t.Errorf("%q: got %+v want %+v", c.user, got, c.want)
		}
	}
	for _, user := range []string{"nobody", "nginx:nogroup", "4294967295"} {
		if _, err := resolveIdentity(root, user, nil); err == nil {
			t.Errorf("%q resolved", user)
		}
	}
	if _, err := resolveIdentity(root, "0", []string{"nogroup"}); err == nil {
		t.Error("unknown group_add resolved")
	}
}

func TestDockerEnv(t *testing.T) {
	env := dockerEnv("abc", "/root",
		[]string{"PATH=/bin", "A=1", "B=2", "A=3"},
		[]string{"B", "C=4=5"})
	want := []string{"PATH=/bin", "HOSTNAME=abc", "A=3", "C=4=5", "HOME=/root"}
	if !slices.Equal(env, want) {
		t.Fatalf("got %q want %q", env, want)
	}
	env = dockerEnv("abc", "/root", []string{"HOME=/custom", "HOSTNAME=mine"})
	if !slices.Equal(env, []string{"PATH=" + defaultPath, "HOSTNAME=mine", "HOME=/custom"}) {
		t.Fatalf("got %q", env)
	}
}

func TestExecEnvTakesOnlyNamedVariables(t *testing.T) {
	environ := []string{"A=1", "HOME=/incus", "PATH=/incus", "B=x y", "OPSMARU_EXEC_ENV=[\"B\",\"A\",\"MISSING\"]", "OPSMARU_EXEC_UNSET=[\"C\"]"}
	layer, err := execEnv(environ)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(layer, []string{"B=x y", "A=1", "C"}) {
		t.Fatalf("got %q", layer)
	}
	if _, err := execEnv([]string{"OPSMARU_EXEC_ENV=nope"}); err == nil {
		t.Error("malformed name list accepted")
	}
}

func TestLookPathAndStartFailures(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, "tool"), "#!/bin/sh\n")
	if err := os.Chmod(filepath.Join(dir, "tool"), 0o755); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(dir, "data"), "x")
	env := []string{"PATH=/nonexistent:" + dir}

	if path, err := lookPath("tool", env, "/"); err != nil || path != filepath.Join(dir, "tool") {
		t.Fatalf("tool: %q %v", path, err)
	}
	if path, err := lookPath("./relative", env, "/"); err != nil || path != "./relative" {
		t.Fatalf("relative: %q %v", path, err)
	}
	_, err := lookPath("missing", env, "/")
	if failure := startFailure(err); failure.code != 127 || !strings.Contains(failure.message, `"missing": executable file not found in $PATH`) {
		t.Fatalf("missing: %+v", failure)
	}
	_, err = lookPath("data", env, "/")
	if failure := startFailure(err); failure.code != 126 {
		t.Fatalf("not executable: %+v", failure)
	}
	if startFailure(&os.PathError{Op: "fork/exec", Path: "/x", Err: syscall.ENOENT}).code != 127 ||
		startFailure(&os.PathError{Op: "fork/exec", Path: "/x", Err: syscall.EACCES}).code != 126 ||
		startFailure(errors.New("other")).code != 128 {
		t.Fatal("errno mapping")
	}
}

func TestSignals(t *testing.T) {
	for input, want := range map[string]syscall.Signal{"SIGHUP": syscall.SIGHUP, "hup": syscall.SIGHUP, "9": syscall.SIGKILL, "TERM": syscall.SIGTERM} {
		if got, err := parseSignal(input); err != nil || got != want {
			t.Errorf("%s: %v %v", input, got, err)
		}
	}
	for _, input := range []string{"", "0", "65", "SIGNOPE"} {
		if _, err := parseSignal(input); err == nil {
			t.Errorf("%q accepted", input)
		}
	}
	if signalName(syscall.SIGKILL) != "SIGKILL" {
		t.Error("signal name")
	}
}

func TestOOMKills(t *testing.T) {
	path := filepath.Join(t.TempDir(), "memory.events")
	mustWrite(t, path, "low 0\nhigh 0\nmax 2\noom 1\noom_kill 3\n")
	if count, ok := readOOMKills(path); !ok || count != 3 {
		t.Fatalf("%d %v", count, ok)
	}
	if _, ok := readOOMKills(path + ".missing"); ok {
		t.Error("missing file read")
	}
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
