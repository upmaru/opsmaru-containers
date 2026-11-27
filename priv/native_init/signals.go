package main

import (
	"fmt"
	"strconv"
	"strings"
	"syscall"
)

var signalNames = map[string]syscall.Signal{
	"ABRT": syscall.SIGABRT, "ALRM": syscall.SIGALRM, "BUS": syscall.SIGBUS,
	"CHLD": syscall.SIGCHLD, "CONT": syscall.SIGCONT, "FPE": syscall.SIGFPE,
	"HUP": syscall.SIGHUP, "ILL": syscall.SIGILL, "INT": syscall.SIGINT,
	"IO": syscall.SIGIO, "KILL": syscall.SIGKILL, "PIPE": syscall.SIGPIPE,
	"PROF": syscall.SIGPROF, "QUIT": syscall.SIGQUIT, "SEGV": syscall.SIGSEGV,
	"STOP": syscall.SIGSTOP, "SYS": syscall.SIGSYS, "TERM": syscall.SIGTERM,
	"TRAP": syscall.SIGTRAP, "TSTP": syscall.SIGTSTP, "TTIN": syscall.SIGTTIN,
	"TTOU": syscall.SIGTTOU, "URG": syscall.SIGURG, "USR1": syscall.SIGUSR1,
	"USR2": syscall.SIGUSR2, "VTALRM": syscall.SIGVTALRM, "WINCH": syscall.SIGWINCH,
	"XCPU": syscall.SIGXCPU, "XFSZ": syscall.SIGXFSZ,
}

// parseSignal accepts Docker's forms: "SIGHUP", "HUP" or a number.
func parseSignal(value string) (syscall.Signal, error) {
	if number, err := strconv.Atoi(value); err == nil {
		if number < 1 || number > 64 {
			return 0, fmt.Errorf("invalid signal %q", value)
		}
		return syscall.Signal(number), nil
	}
	name := strings.TrimPrefix(strings.ToUpper(value), "SIG")
	if signal, ok := signalNames[name]; ok {
		return signal, nil
	}
	return 0, fmt.Errorf("invalid signal %q", value)
}

func signalName(signal syscall.Signal) string {
	for name, value := range signalNames {
		if value == signal {
			return "SIG" + name
		}
	}
	return strconv.Itoa(int(signal))
}
