package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

const recordLimit = 64 << 10

// RunRecord is /.opsmaru/state/run.json, version 1.
type RunRecord struct {
	Version    int     `json:"version"`
	Run        uint32  `json:"run"`
	Pid        int     `json:"pid,omitempty"`
	StartedAt  string  `json:"started_at"`
	FinishedAt *string `json:"finished_at"`
	ExitCode   *int    `json:"exit_code"`
	Signal     *string `json:"signal"`
	OOMKilled  bool    `json:"oom_killed"`
	Error      *string `json:"error"`
}

func readRun(path string) (RunRecord, error) {
	data, err := readLimited(path, recordLimit)
	if err != nil {
		return RunRecord{}, err
	}
	var record RunRecord
	if err := json.Unmarshal(data, &record); err != nil {
		return RunRecord{}, err
	}
	if record.Version != 1 {
		return RunRecord{}, errors.New("run record version is not supported")
	}
	return record, nil
}

// writeRun replaces the record atomically: a synced temporary file is renamed
// over it, and the directory is synced so the rename survives a crash.
func writeRun(path string, record RunRecord) error {
	record.Version = 1
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	return writeAtomic(path, append(data, '\n'))
}

func writeAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	temp, err := os.CreateTemp(dir, ".run-*.tmp")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer os.Remove(name)
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	return syncDir(dir)
}

func syncDir(dir string) error {
	handle, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer handle.Close()
	return handle.Sync()
}

func timestamp(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

func ptr[T any](value T) *T { return &value }
