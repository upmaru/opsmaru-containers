package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

const (
	specLimit      = 1 << 20
	minLogSize     = 4096
	defaultLogSize = 20 << 20
	defaultLogKeep = 5
)

// Spec is /.opsmaru/spec.json, version 1.
type Spec struct {
	Version    int      `json:"version"`
	Argv       []string `json:"argv"`
	Env        []string `json:"env"`
	Cwd        string   `json:"cwd"`
	User       string   `json:"user"`
	GroupAdd   []string `json:"group_add"`
	Hostname   string   `json:"hostname"`
	StopSignal string   `json:"stop_signal"`
	Log        LogSpec  `json:"log"`
}

// LogSpec selects the log driver and its rotation.
type LogSpec struct {
	Driver   string `json:"driver"`
	MaxSize  int64  `json:"max_size"`
	MaxFiles int    `json:"max_files"`
}

func loadSpec(path string) (Spec, error) {
	data, err := readLimited(path, specLimit)
	if err != nil {
		return Spec{}, fmt.Errorf("read spec: %w", err)
	}
	return parseSpec(data)
}

func parseSpec(data []byte) (Spec, error) {
	var spec Spec
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&spec); err != nil {
		return Spec{}, fmt.Errorf("parse spec: %w", err)
	}
	if decoder.More() {
		return Spec{}, errors.New("parse spec: trailing data")
	}
	return spec, spec.validate()
}

func (spec *Spec) validate() error {
	if spec.Version != 1 {
		return fmt.Errorf("spec version %d is not supported", spec.Version)
	}
	if len(spec.Argv) == 0 || spec.Argv[0] == "" {
		return errors.New("spec argv is empty")
	}
	for _, arg := range spec.Argv {
		if strings.ContainsRune(arg, 0) {
			return errors.New("spec argv contains a NUL byte")
		}
	}
	for _, entry := range spec.Env {
		if entry == "" || strings.HasPrefix(entry, "=") || strings.ContainsRune(entry, 0) {
			return fmt.Errorf("spec env entry %q is invalid", entry)
		}
	}
	if spec.Cwd == "" {
		spec.Cwd = "/"
	}
	if !strings.HasPrefix(spec.Cwd, "/") {
		return fmt.Errorf("spec cwd %q is not absolute", spec.Cwd)
	}
	if strings.ContainsAny(spec.Hostname, "\x00/") || len(spec.Hostname) > 64 {
		return fmt.Errorf("spec hostname %q is invalid", spec.Hostname)
	}
	if spec.StopSignal == "" {
		spec.StopSignal = "SIGTERM"
	}
	if _, err := parseSignal(spec.StopSignal); err != nil {
		return fmt.Errorf("spec stop_signal: %w", err)
	}
	switch spec.Log.Driver {
	case "", "local", "json-file":
		spec.Log.Driver = "local"
	case "none":
	default:
		return fmt.Errorf("spec log driver %q is not supported", spec.Log.Driver)
	}
	if spec.Log.MaxSize == 0 {
		spec.Log.MaxSize = defaultLogSize
	}
	if spec.Log.MaxFiles == 0 {
		spec.Log.MaxFiles = defaultLogKeep
	}
	if spec.Log.MaxSize < minLogSize || spec.Log.MaxFiles < 1 || spec.Log.MaxFiles > 10000 {
		return errors.New("spec log rotation is out of range")
	}
	return nil
}

func readLimited(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s is larger than %d bytes", path, limit)
	}
	return data, nil
}
