package main

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
)

const drainTimeout = time.Second

// System is the kernel setup init needs. Tests on other systems use no-ops.
type System interface {
	SetHostname(name string) error
	SetSubreaper() error
}

type child struct {
	pid      int
	exited   bool
	status   syscall.WaitStatus
	killTime *time.Timer
}

func runInit(paths Paths, system System) int {
	signals := make(chan os.Signal, 16)
	signal.Notify(signals, syscall.SIGCHLD, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP,
		syscall.SIGQUIT, syscall.SIGUSR1, syscall.SIGUSR2, syscall.SIGWINCH)
	defer signal.Stop(signals)

	for _, dir := range []string{paths.State, paths.Logs} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			warn("create %s: %v", dir, err)
			return 128
		}
	}

	spec, specErr := loadSpec(paths.Spec)
	logSpec := LogSpec{Driver: "local", MaxSize: defaultLogSize, MaxFiles: defaultLogKeep}
	if specErr == nil {
		logSpec = spec.Log
	}
	logger, err := openLogger(paths.Logs, logSpec)
	if err != nil {
		warn("open logs: %v", err)
		return 128
	}

	run := uint32(1)
	if previous, err := readRun(paths.Run); err == nil {
		run = previous.Run + 1
	} else if !errors.Is(err, os.ErrNotExist) {
		warn("previous run record unreadable: %v", err)
	}
	if logger.lastRun >= run {
		run = logger.lastRun + 1
	}

	started := time.Now()
	fail := func(failure *startError) int {
		warn("%s", failure.message)
		_ = logger.Close()
		finished := timestamp(time.Now())
		record := RunRecord{Run: run, StartedAt: timestamp(started), FinishedAt: &finished,
			ExitCode: ptr(failure.code), Error: ptr(failure.message)}
		if err := writeRun(paths.Run, record); err != nil {
			warn("write run record: %v", err)
		}
		return failure.code
	}
	if specErr != nil {
		return fail(&startError{128, specErr.Error()})
	}

	if spec.Hostname != "" {
		if err := system.SetHostname(spec.Hostname); err != nil {
			warn("set hostname: %v", err)
		}
	}
	if err := system.SetSubreaper(); err != nil {
		warn("set child subreaper: %v", err)
	}

	identity, err := resolveIdentity(paths.Root, spec.User, spec.GroupAdd)
	if err != nil {
		return fail(&startError{128, err.Error()})
	}
	env := dockerEnv(spec.Hostname, identity.Home, spec.Env)
	path, err := lookPath(spec.Argv[0], env, spec.Cwd)
	if err != nil {
		return fail(startFailure(err))
	}
	credential, err := credentialFor(identity)
	if err != nil {
		return fail(&startError{128, err.Error()})
	}

	devNull, err := os.Open(os.DevNull)
	if err != nil {
		return fail(&startError{128, err.Error()})
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		return fail(&startError{128, err.Error()})
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		return fail(&startError{128, err.Error()})
	}

	oomBefore, oomKnown := readOOMKills(paths.CgroupEvents)
	started = time.Now()
	process, err := os.StartProcess(path, spec.Argv, &os.ProcAttr{
		Dir:   spec.Cwd,
		Env:   env,
		Files: []*os.File{devNull, stdoutW, stderrW},
		Sys:   &syscall.SysProcAttr{Credential: credential},
	})
	devNull.Close()
	stdoutW.Close()
	stderrW.Close()
	if err != nil {
		stdoutR.Close()
		stderrR.Close()
		return fail(startFailure(cwdError(spec.Cwd, err)))
	}

	copiers := []*copier{
		startCopier(stdoutR, streamStdout, run, logger),
		startCopier(stderrR, streamStderr, run, logger),
	}
	record := RunRecord{Run: run, Pid: process.Pid, StartedAt: timestamp(started)}
	if err := writeRun(paths.Run, record); err != nil {
		warn("write run record: %v", err)
	}

	calls := make(chan controlCall)
	if listener, err := serveControl(paths.Control, calls); err != nil {
		warn("control socket: %v", err)
	} else {
		defer listener.Close()
		defer os.Remove(paths.Control)
	}

	current := &child{pid: process.Pid}
	killNow := make(chan struct{}, 1)
	reap(current)
	for !current.exited {
		select {
		case received := <-signals:
			switch received {
			case syscall.SIGCHLD:
				reap(current)
			case syscall.SIGTERM:
				stopSignal, _ := parseSignal(spec.StopSignal)
				_ = syscall.Kill(current.pid, stopSignal)
			default:
				_ = syscall.Kill(current.pid, received.(syscall.Signal))
			}
		case call := <-calls:
			call.reply <- control(current, spec, call.request, killNow)
		case <-killNow:
			_ = syscall.Kill(current.pid, syscall.SIGKILL)
		}
	}
	if current.killTime != nil {
		current.killTime.Stop()
	}
	finished := time.Now()

	deadline := time.Now().Add(drainTimeout)
	for _, c := range copiers {
		c.drain(deadline)
	}
	if err := logger.Close(); err != nil {
		warn("close logs: %v", err)
	}

	code, signalled := exitCode(current.status)
	record.FinishedAt = ptr(timestamp(finished))
	record.ExitCode = ptr(code)
	if signalled != 0 {
		record.Signal = ptr(signalName(signalled))
	}
	if oomAfter, ok := readOOMKills(paths.CgroupEvents); ok && oomKnown && oomAfter > oomBefore {
		record.OOMKilled = true
	}
	if err := writeRun(paths.Run, record); err != nil {
		warn("write run record: %v", err)
	}
	return code
}

// cwdError names a missing working directory as runc does; the error from
// starting the process names only the program.
func cwdError(cwd string, err error) error {
	if _, statErr := os.Stat(cwd); statErr != nil {
		var pathErr *os.PathError
		if errors.As(statErr, &pathErr) {
			return fmt.Errorf("chdir to cwd (%q) set in config.json failed: %w", cwd, pathErr.Err)
		}
	}
	return err
}

// reap collects every exited descendant; the shim is their subreaper.
func reap(current *child) {
	for {
		var status syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &status, syscall.WNOHANG, nil)
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if err != nil || pid <= 0 {
			return
		}
		if pid == current.pid && (status.Exited() || status.Signaled()) {
			current.exited = true
			current.status = status
		}
	}
}

func control(current *child, spec Spec, request controlRequest, killNow chan<- struct{}) controlResponse {
	if current.exited {
		return controlResponse{Error: "container is not running"}
	}
	switch request.Op {
	case "kill":
		sig, err := parseSignal(request.Signal)
		if err != nil {
			return controlResponse{Error: err.Error()}
		}
		if err := syscall.Kill(current.pid, sig); err != nil {
			return controlResponse{Error: err.Error()}
		}
		return controlResponse{OK: true}
	case "stop":
		name := request.Signal
		if name == "" {
			name = spec.StopSignal
		}
		sig, err := parseSignal(name)
		if err != nil {
			return controlResponse{Error: err.Error()}
		}
		if err := syscall.Kill(current.pid, sig); err != nil {
			return controlResponse{Error: err.Error()}
		}
		timeout := 10
		if request.Timeout != nil {
			timeout = *request.Timeout
		}
		if timeout >= 0 {
			if current.killTime != nil {
				current.killTime.Stop()
			}
			current.killTime = time.AfterFunc(time.Duration(timeout)*time.Second, func() {
				select {
				case killNow <- struct{}{}:
				default:
				}
			})
		}
		return controlResponse{OK: true}
	default:
		return controlResponse{Error: fmt.Sprintf("unknown operation %q", request.Op)}
	}
}

func exitCode(status syscall.WaitStatus) (int, syscall.Signal) {
	if status.Signaled() {
		return 128 + int(status.Signal()), status.Signal()
	}
	return status.ExitStatus(), 0
}

// credentialFor drops to the process identity. Only root can change it, so a
// non-root shim (in tests) may run the child only as itself.
func credentialFor(identity Identity) (*syscall.Credential, error) {
	if os.Geteuid() == 0 {
		return &syscall.Credential{Uid: identity.UID, Gid: identity.GID, Groups: identity.Groups}, nil
	}
	if identity.UID == uint32(os.Geteuid()) && identity.GID == uint32(os.Getegid()) && len(identity.Groups) == 0 {
		return nil, nil
	}
	return nil, errors.New("changing the user requires root")
}
