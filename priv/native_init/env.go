package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// dockerEnv builds a process environment as dockerd and runc do: PATH and
// HOSTNAME first, then each layer replaces or appends, and HOME is added
// last when unset.
func dockerEnv(hostname, home string, layers ...[]string) []string {
	env := []string{"PATH=" + defaultPath, "HOSTNAME=" + hostname}
	for _, layer := range layers {
		env = replaceOrAppend(env, layer)
	}
	if _, ok := lookupEnv(env, "HOME"); !ok {
		env = append(env, "HOME="+home)
	}
	return env
}

// replaceOrAppend is dockerd's ReplaceOrAppendEnvValues: an entry without
// "=" removes that variable.
func replaceOrAppend(env, overrides []string) []string {
	for _, override := range overrides {
		key, _, hasValue := strings.Cut(override, "=")
		index := -1
		for i, entry := range env {
			if entryKey, _, _ := strings.Cut(entry, "="); entryKey == key {
				index = i
				break
			}
		}
		switch {
		case !hasValue && index >= 0:
			env = append(env[:index], env[index+1:]...)
		case !hasValue:
		case index >= 0:
			env[index] = override
		default:
			env = append(env, override)
		}
	}
	return env
}

func lookupEnv(env []string, key string) (string, bool) {
	value, found := "", false
	for _, entry := range env {
		if entryKey, entryValue, ok := strings.Cut(entry, "="); ok && entryKey == key {
			value, found = entryValue, true
		}
	}
	return value, found
}

// startError is a process that could not be started, with Docker's exit code.
type startError struct {
	code    int
	message string
}

func (e *startError) Error() string { return e.message }

// lookPath resolves argv[0] against the child's PATH, as Docker does.
func lookPath(name string, env []string, cwd string) (string, error) {
	if strings.Contains(name, "/") {
		return name, nil
	}
	path, _ := lookupEnv(env, "PATH")
	denied := false
	for dir := range strings.SplitSeq(path, ":") {
		if dir == "" {
			dir = "."
		}
		candidate := filepath.Join(dir, name)
		check := candidate
		if !filepath.IsAbs(check) {
			check = filepath.Join(cwd, check)
		}
		info, err := os.Stat(check)
		if err != nil || info.IsDir() {
			continue
		}
		if info.Mode()&0o111 == 0 {
			denied = true
			continue
		}
		return candidate, nil
	}
	if denied {
		return "", &startError{126, fmt.Sprintf("exec: %q: permission denied", name)}
	}
	return "", &startError{127, fmt.Sprintf("exec: %q: executable file not found in $PATH", name)}
}

// startFailure maps an error from starting a process to Docker's exit codes:
// 127 for a missing file, 126 for permission, 128 for anything else.
func startFailure(err error) *startError {
	var known *startError
	if errors.As(err, &known) {
		return known
	}
	switch {
	case errors.Is(err, fs.ErrNotExist), errors.Is(err, syscall.ENOENT), errors.Is(err, syscall.ENOTDIR):
		return &startError{127, err.Error()}
	case errors.Is(err, fs.ErrPermission), errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		return &startError{126, err.Error()}
	default:
		return &startError{128, err.Error()}
	}
}
