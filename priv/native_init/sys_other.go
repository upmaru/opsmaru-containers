//go:build !linux

package main

// hostSystem lets the shim's tests run on development hosts. The shim is only
// released for Linux.
type hostSystem struct{}

func (hostSystem) SetHostname(string) error { return nil }

func (hostSystem) SetSubreaper() error { return nil }
