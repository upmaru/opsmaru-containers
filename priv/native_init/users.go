package main

import (
	"bufio"
	"bytes"
	"fmt"
	"math"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

const accountFileLimit = 4 << 20

// Identity is the resolved user of a process.
type Identity struct {
	UID    uint32
	GID    uint32
	Groups []uint32
	Home   string
}

type passwdEntry struct {
	name string
	uid  uint32
	gid  uint32
	home string
}

type groupEntry struct {
	name    string
	gid     uint32
	members []string
}

// resolveIdentity follows runc's rules for Docker's User field: "user",
// "uid", "user:group" or "uid:gid", resolved against the container's
// /etc/passwd and /etc/group. Supplementary groups come from /etc/group when
// no group is given. groupAdd entries are always added.
func resolveIdentity(root, user string, groupAdd []string) (Identity, error) {
	passwd := readPasswd(filepath.Join(root, "etc/passwd"))
	groups := readGroups(filepath.Join(root, "etc/group"))

	userPart, groupPart, hasGroup := strings.Cut(user, ":")
	if userPart == "" {
		userPart = "0"
	}

	identity := Identity{Home: "/"}
	var name string
	if uid, ok := parseID(userPart); ok {
		identity.UID = uid
		if entry, found := findPasswd(passwd, func(e passwdEntry) bool { return e.uid == uid }); found {
			identity.GID, identity.Home, name = entry.gid, entry.home, entry.name
		}
	} else {
		entry, found := findPasswd(passwd, func(e passwdEntry) bool { return e.name == userPart })
		if !found {
			return Identity{}, fmt.Errorf("unable to find user %s: no matching entries in passwd file", userPart)
		}
		identity.UID, identity.GID, identity.Home, name = entry.uid, entry.gid, entry.home, entry.name
	}

	if hasGroup {
		gid, err := resolveGroup(groups, groupPart)
		if err != nil {
			return Identity{}, err
		}
		identity.GID = gid
	} else if name != "" {
		for _, group := range groups {
			if slices.Contains(group.members, name) && group.gid != identity.GID {
				identity.Groups = append(identity.Groups, group.gid)
			}
		}
	}

	for _, extra := range groupAdd {
		gid, err := resolveGroup(groups, extra)
		if err != nil {
			return Identity{}, err
		}
		identity.Groups = append(identity.Groups, gid)
	}
	slices.Sort(identity.Groups)
	identity.Groups = slices.Compact(identity.Groups)
	if identity.Home == "" {
		identity.Home = "/"
	}
	return identity, nil
}

func resolveGroup(groups []groupEntry, value string) (uint32, error) {
	if gid, ok := parseID(value); ok {
		return gid, nil
	}
	for _, group := range groups {
		if group.name == value {
			return group.gid, nil
		}
	}
	return 0, fmt.Errorf("unable to find group %s: no matching entries in group file", value)
}

func parseID(value string) (uint32, bool) {
	id, err := strconv.ParseUint(value, 10, 32)
	if err != nil || id == math.MaxUint32 {
		return 0, false
	}
	return uint32(id), true
}

func findPasswd(entries []passwdEntry, match func(passwdEntry) bool) (passwdEntry, bool) {
	for _, entry := range entries {
		if match(entry) {
			return entry, true
		}
	}
	return passwdEntry{}, false
}

func readPasswd(path string) []passwdEntry {
	var entries []passwdEntry
	eachLine(path, func(fields []string) {
		if len(fields) < 7 {
			return
		}
		uid, uidOK := parseID(fields[2])
		gid, gidOK := parseID(fields[3])
		if fields[0] == "" || !uidOK || !gidOK {
			return
		}
		entries = append(entries, passwdEntry{name: fields[0], uid: uid, gid: gid, home: fields[5]})
	})
	return entries
}

func readGroups(path string) []groupEntry {
	var entries []groupEntry
	eachLine(path, func(fields []string) {
		if len(fields) < 4 {
			return
		}
		gid, ok := parseID(fields[2])
		if fields[0] == "" || !ok {
			return
		}
		var members []string
		for member := range strings.SplitSeq(fields[3], ",") {
			if member = strings.TrimSpace(member); member != "" {
				members = append(members, member)
			}
		}
		entries = append(entries, groupEntry{name: fields[0], gid: gid, members: members})
	})
	return entries
}

// eachLine reads an account file. A missing or oversized file reads as empty,
// as runc treats a missing one.
func eachLine(path string, handle func([]string)) {
	data, err := readLimited(path, accountFileLimit)
	if err != nil {
		return
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 64<<10), accountFileLimit)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		handle(strings.Split(line, ":"))
	}
}
