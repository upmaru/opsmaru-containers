// native_init is the init shim of an opsmaru_containers native container.
//
// With no argument it runs as the container's entrypoint: it reads the process
// spec from /.opsmaru/spec.json, starts the process, records each run and its
// exit status in /.opsmaru/state/run.json, and writes stdout and stderr as log
// records under /.opsmaru/logs. The exec, kill and stop modes are run by the
// library through Incus exec. See README.md for the file formats.
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		os.Exit(runInit(defaultPaths(), hostSystem{}))
	}

	switch os.Args[1] {
	case "exec":
		os.Exit(runExec(defaultPaths(), os.Args[2:]))
	case "kill":
		os.Exit(runKill(defaultPaths(), os.Args[2:]))
	case "stop":
		os.Exit(runStop(defaultPaths(), os.Args[2:]))
	default:
		fmt.Fprintln(os.Stderr, "usage: init | init exec [--user U] [--cwd D] -- ARGV... | init kill SIGNAL | init stop [--signal S] [--timeout SECONDS]")
		os.Exit(2)
	}
}

// Paths are the shim's files. Tests use a temporary root.
type Paths struct {
	Spec    string
	State   string
	Run     string
	Control string
	Logs    string
	// Root is the directory that holds etc/passwd and etc/group.
	Root string
	// CgroupEvents is the cgroup v2 memory.events file.
	CgroupEvents string
}

func defaultPaths() Paths {
	return Paths{
		Spec:         "/.opsmaru/spec.json",
		State:        "/.opsmaru/state",
		Run:          "/.opsmaru/state/run.json",
		Control:      "/.opsmaru/state/control.sock",
		Logs:         "/.opsmaru/logs",
		Root:         "/",
		CgroupEvents: "/sys/fs/cgroup/memory.events",
	}
}

func warn(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "opsmaru-init: "+format+"\n", args...)
}
