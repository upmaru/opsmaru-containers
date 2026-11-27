package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"syscall"
)

const (
	execEnvNames = "OPSMARU_EXEC_ENV"
	execEnvUnset = "OPSMARU_EXEC_UNSET"
)

// runExec prepares a Docker exec and replaces itself with the command, so no
// shim process remains and the exit code and TTY are the command's own.
//
// The exec's own environment arrives in the Incus exec environment. Only the
// variables named, in order, by the JSON array in OPSMARU_EXEC_ENV are taken
// from it, so variables Incus adds are dropped. OPSMARU_EXEC_UNSET names
// variables to remove, as a Docker Env entry without "=" does.
func runExec(paths Paths, args []string) int {
	flags := flag.NewFlagSet("exec", flag.ContinueOnError)
	user := flags.String("user", "", "user[:group]; the container's user when empty")
	cwd := flags.String("cwd", "", "working directory; the container's when empty")
	if err := flags.Parse(args); err != nil || flags.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: init exec [--user U] [--cwd D] -- ARGV...")
		return 2
	}
	argv := flags.Args()

	spec, err := loadSpec(paths.Spec)
	if err != nil {
		return execFailure(&startError{128, err.Error()})
	}
	if *user == "" {
		*user = spec.User
	}
	if *cwd == "" {
		*cwd = spec.Cwd
	}
	layer, err := execEnv(os.Environ())
	if err != nil {
		return execFailure(&startError{128, err.Error()})
	}
	identity, err := resolveIdentity(paths.Root, *user, spec.GroupAdd)
	if err != nil {
		return execFailure(&startError{128, err.Error()})
	}
	env := dockerEnv(spec.Hostname, identity.Home, spec.Env, layer)
	path, err := lookPath(argv[0], env, *cwd)
	if err != nil {
		return execFailure(startFailure(err))
	}
	if err := becomeIdentity(identity); err != nil {
		return execFailure(&startError{128, err.Error()})
	}
	if err := os.Chdir(*cwd); err != nil {
		return execFailure(startFailure(err))
	}
	err = syscall.Exec(path, argv, env)
	return execFailure(startFailure(err))
}

func execEnv(environ []string) ([]string, error) {
	var names, unset []string
	if value, ok := lookupEnv(environ, execEnvNames); ok && value != "" {
		if err := json.Unmarshal([]byte(value), &names); err != nil {
			return nil, fmt.Errorf("%s: %w", execEnvNames, err)
		}
	}
	if value, ok := lookupEnv(environ, execEnvUnset); ok && value != "" {
		if err := json.Unmarshal([]byte(value), &unset); err != nil {
			return nil, fmt.Errorf("%s: %w", execEnvUnset, err)
		}
	}
	var layer []string
	for _, name := range names {
		if value, ok := lookupEnv(environ, name); ok {
			layer = append(layer, name+"="+value)
		}
	}
	return append(layer, unset...), nil
}

func becomeIdentity(identity Identity) error {
	if os.Geteuid() != 0 {
		_, err := credentialFor(identity)
		return err
	}
	groups := make([]int, len(identity.Groups))
	for i, gid := range identity.Groups {
		groups[i] = int(gid)
	}
	if err := syscall.Setgroups(groups); err != nil {
		return fmt.Errorf("setgroups: %w", err)
	}
	if err := syscall.Setgid(int(identity.GID)); err != nil {
		return fmt.Errorf("setgid: %w", err)
	}
	if err := syscall.Setuid(int(identity.UID)); err != nil {
		return fmt.Errorf("setuid: %w", err)
	}
	return nil
}

func execFailure(failure *startError) int {
	fmt.Fprintln(os.Stderr, failure.message)
	return failure.code
}
