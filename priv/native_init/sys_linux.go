//go:build linux

package main

import "syscall"

const prSetChildSubreaper = 36

type hostSystem struct{}

func (hostSystem) SetHostname(name string) error {
	return syscall.Sethostname([]byte(name))
}

func (hostSystem) SetSubreaper() error {
	_, _, errno := syscall.RawSyscall(syscall.SYS_PRCTL, prSetChildSubreaper, 1, 0)
	if errno != 0 {
		return errno
	}
	return nil
}
