// Command llmctl-decide is the Go decision layer of llmctl: the HTTPS decision
// gateway, the `decide` client and key/certificate management in one binary.
//
// Subcommands register themselves from their own file via register() in an
// init function, so independent packages never edit this file.
package main

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
)

// command runs one subcommand and returns the process exit code.
type command func(args []string, stdout, stderr io.Writer) int

var commands = map[string]command{}

// register adds a subcommand; it panics on a duplicate name (programming error).
func register(name string, c command) {
	if _, dup := commands[name]; dup {
		panic("llmctl-decide: duplicate subcommand " + name)
	}
	commands[name] = c
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "usage: llmctl-decide <%s> [flags]\n", strings.Join(names(), "|"))
		return 2
	}
	c, ok := commands[args[0]]
	if !ok {
		fmt.Fprintf(stderr, "llmctl-decide: unknown subcommand %q (known: %s)\n", args[0], strings.Join(names(), ", "))
		return 2
	}
	return c(args[1:], stdout, stderr)
}

func names() []string {
	n := make([]string, 0, len(commands))
	for k := range commands {
		n = append(n, k)
	}
	sort.Strings(n)
	return n
}

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }
