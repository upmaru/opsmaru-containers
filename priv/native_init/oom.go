package main

import (
	"strconv"
	"strings"
)

// readOOMKills reads oom_kill from a cgroup v2 memory.events file.
func readOOMKills(path string) (uint64, bool) {
	data, err := readLimited(path, 4096)
	if err != nil {
		return 0, false
	}
	for line := range strings.SplitSeq(string(data), "\n") {
		if value, ok := strings.CutPrefix(line, "oom_kill "); ok {
			count, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64)
			return count, err == nil
		}
	}
	return 0, false
}
