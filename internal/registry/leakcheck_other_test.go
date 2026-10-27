//go:build !linux

package registry

func reportAndReapLeaks(string) bool { return false }
