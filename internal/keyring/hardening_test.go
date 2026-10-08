package keyring

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A-03: rotating with a grace period while the environment shadows the file key must NOT re-arm the
// file key as an accepted "previous" key.
func TestRotateGraceUnderEnvShadowDoesNotWidenTheAcceptedSet(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600) // F: the old file key, shadowed by the env key E
	env := Environ{"LLMCTL_API_KEY": goodKey2}     // E
	now := time.Unix(10_000, 0)
	before, err := AcceptedKeys(f.dir, env, now)
	if err != nil || len(before) != 1 || before[0].Reveal() != goodKey2 {
		t.Fatalf("before rotation only E is accepted: %v %d", err, len(before))
	}
	r, err := Rotate(f.dir, env, 3600, now)
	if err != nil {
		t.Fatal(err)
	}
	if r.PreviousExpires != 0 || !r.GraceSkipped || !r.EnvShadows {
		t.Fatalf("grace must be skipped and reported: %+v", r)
	}
	if c := f.read(); contains(c, "PREVIOUS") || contains(c, goodKey) {
		t.Fatalf("the shadowed old key must not be kept as PREVIOUS: %q", c)
	}
	after, err := AcceptedKeys(f.dir, env, now)
	if err != nil || len(after) != 1 || after[0].Reveal() != goodKey2 {
		t.Fatalf("the accepted set must not have widened: %d keys (err %v)", len(after), err)
	}
	for _, k := range after {
		if k.Reveal() == goodKey {
			t.Fatal("the old shadowed key F is accepted after rotate --grace")
		}
	}
}

func TestRotateGraceIsAppliedWhenTheOldKeyWasAccepted(t *testing.T) {
	// control 1: no environment key
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	r, err := Rotate(f.dir, Environ{}, 60, time.Unix(1, 0))
	if err != nil || r.PreviousExpires == 0 || r.GraceSkipped || !contains(f.read(), "PREVIOUS="+goodKey) {
		t.Fatalf("%+v %v", r, err)
	}
	// control 2: the environment key equals the file key (the file key IS accepted)
	g := newFixture(t)
	g.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	r, err = Rotate(g.dir, Environ{"LLMCTL_API_KEY": goodKey}, 60, time.Unix(1, 0))
	if err != nil || r.PreviousExpires == 0 || r.GraceSkipped {
		t.Fatalf("%+v %v", r, err)
	}
	// a stale PREVIOUS from an earlier rotation is cleared when grace is skipped
	h := newFixture(t)
	h.write("LLMCTL_API_KEY="+goodKey+"\nLLMCTL_API_KEY_PREVIOUS="+goodKey2+"\nLLMCTL_API_KEY_PREVIOUS_EXPIRES=99999999999\n", 0o600)
	if _, err := Rotate(h.dir, Environ{"LLMCTL_API_KEY": "Zz9" + goodKey2[3:]}, 60, time.Unix(1, 0)); err != nil {
		t.Fatal(err)
	}
	if contains(h.read(), "PREVIOUS") {
		t.Fatalf("stale PREVIOUS survived: %q", h.read())
	}
}

func TestCLIRotateExplainsASkippedGrace(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	r := runCLI(f.dir, Environ{"LLMCTL_API_KEY": goodKey2}, "rotate", "--grace", "60")
	if r.rc != 0 || !contains(r.out, "--grace was NOT applied") || contains(r.out+r.err, goodKey) || contains(r.out+r.err, goodKey2) {
		t.Fatalf("%+v", r)
	}
}

// A-07: both operands of the constant-time primitive are fixed-length digests, whatever the lengths
// of the candidate and the accepted keys.
func TestKeyMatchesComparesFixedLengthDigests(t *testing.T) {
	old := ctEqual
	defer func() { ctEqual = old }()
	var lens [][2]int
	ctEqual = func(a, b []byte) int { lens = append(lens, [2]int{len(a), len(b)}); return old(a, b) }
	short := goodKey
	long := strings.Repeat("kL9-", 100) + "x" // 401 chars
	acc := []Secret{NewSecret(short), NewSecret(long)}
	for _, cand := range []string{"x", short, long, strings.Repeat("q", 600)} {
		lens = nil
		KeyMatches(cand, acc)
		if len(lens) != len(acc) {
			t.Fatalf("one comparison per accepted key expected, got %d", len(lens))
		}
		for _, l := range lens {
			if l[0] != l[1] || l[0] != 32 {
				t.Fatalf("operands must be 32-byte digests, got %v for candidate len %d", l, len(cand))
			}
		}
	}
	if !KeyMatches(long, acc) || !KeyMatches(short, acc) || KeyMatches("x", acc) {
		t.Error("digest comparison broke matching")
	}
}

// A-12: the env file is opened O_NOFOLLOW|O_NONBLOCK and judged on the opened descriptor.
func TestOpenPrivateRefusesFIFOWithoutBlocking(t *testing.T) {
	p := filepath.Join(t.TempDir(), "fifo.env")
	if err := syscall.Mkfifo(p, 0o600); err != nil {
		t.Skip("mkfifo unavailable: ", err)
	}
	done := make(chan error, 1)
	go func() { _, err := readPrivateText(p); done <- err }()
	select {
	case err := <-done:
		if err == nil || !contains(err.Error(), "not a regular file") {
			t.Fatalf("a FIFO must be refused as not a regular file: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("readPrivateText hung on a FIFO")
	}
}

func TestOpenPrivateRefusesSymlink(t *testing.T) {
	d := t.TempDir()
	real := filepath.Join(d, "real")
	if err := os.WriteFile(real, []byte("A=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(d, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readPrivateText(link); err == nil || !contains(err.Error(), "symlink") {
		t.Fatalf("%v", err)
	}
}

// A-12: tightening is an fchmod on the descriptor that was checked: a symlink swapped in at the path
// between the check and the chmod must NOT redirect the chmod to another file.
func TestTightenChmodsTheCheckedDescriptorNotWhateverIsAtThePathNow(t *testing.T) {
	d := t.TempDir()
	env := filepath.Join(d, ".env")
	victim := filepath.Join(d, "victim")
	if err := os.WriteFile(env, []byte("A=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(env, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(victim, []byte("v"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(victim, 0o644); err != nil {
		t.Fatal(err)
	}
	old := fchmodFn
	defer func() { fchmodFn = old }()
	fchmodFn = func(f *os.File, m os.FileMode) error {
		// the attacker swaps the path for a symlink to the victim right before the chmod
		_ = os.Remove(env)
		_ = os.Symlink(victim, env)
		return old(f, m)
	}
	if err := EnsurePrivate(env); err != nil {
		t.Fatalf("the checked file itself was tightened, so this succeeds: %v", err)
	}
	if st, _ := os.Stat(victim); st.Mode().Perm() != 0o644 {
		t.Fatalf("the swapped-in victim was chmod'ed to %o: the chmod followed the path", st.Mode().Perm())
	}
}

func TestKeyRegexHasAnUpperBound(t *testing.T) {
	if MaxKeyLen != 512 {
		t.Fatalf("MaxKeyLen = %d", MaxKeyLen)
	}
	k := GenerateKey().Reveal()
	for len(k) < MaxKeyLen {
		k += GenerateKey().Reveal()
	}
	if _, err := ValidateKey(k[:MaxKeyLen], "t"); err != nil {
		t.Errorf("a %d-char random key must be accepted: %v", MaxKeyLen, err)
	}
	if _, err := ValidateKey(k[:MaxKeyLen]+"a", "t"); err == nil {
		t.Error("a key one char over the bound must be refused")
	}
}

// The remedy named by the entropy-floor refusal must work: rotating replaces a weak file key.
func TestRotateReplacesAWeakFileKeyAndNeverKeepsItAsPrevious(t *testing.T) {
	f := newFixture(t)
	weak := strings.Repeat("a", 40)
	f.write("LLMCTL_API_KEY="+weak+"\n", 0o600)
	if _, err := Resolve(f.dir, Environ{}, false); err == nil || !contains(err.Error(), "too weak") {
		t.Fatalf("a weak file key is refused at start: %v", err)
	}
	r, err := Rotate(f.dir, Environ{}, 600, time.Unix(5, 0))
	if err != nil {
		t.Fatalf("rotate must replace a weak key: %v", err)
	}
	if !r.GraceSkipped || r.PreviousExpires != 0 {
		t.Fatalf("a weak key was never accepted, so no grace: %+v", r)
	}
	if c := f.read(); contains(c, weak) || contains(c, "PREVIOUS") {
		t.Fatalf("the weak key must be gone: %q", c)
	}
	if res, err := Resolve(f.dir, Environ{}, false); err != nil || res.Key.Reveal() != r.Key.Reveal() {
		t.Fatalf("the rotated key is usable: %v", err)
	}
	// a MALFORMED old value is still refused, not silently replaced
	g := newFixture(t)
	g.write("LLMCTL_API_KEY=short\n", 0o600)
	if _, err := Rotate(g.dir, Environ{}, 0, time.Unix(5, 0)); err == nil {
		t.Fatal("a malformed old key must be refused")
	}
}

// A2-01 / A2-T2: the rotating shell and the gateway have DIFFERENT environments. The gateway has the
// environment key E; the operator's login shell has none. Rotate (CLI env empty) writes the old file
// key F as PREVIOUS, and the gateway (env {E}) must still accept ONLY E.
func TestRotateGraceWithDifferentCLIAndGatewayEnvironmentsDoesNotWidenTheAcceptedSet(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600) // F, possibly the leaked key
	gatewayEnv := Environ{"LLMCTL_API_KEY": goodKey2}
	cliEnv := Environ{} // ordinary login shell: no LLMCTL_API_KEY
	now := time.Unix(10_000, 0)
	before, err := AcceptedKeys(f.dir, gatewayEnv, now)
	if err != nil || len(before) != 1 || before[0].Reveal() != goodKey2 {
		t.Fatalf("before rotation only E is accepted: %v %d", err, len(before))
	}
	if _, err := Rotate(f.dir, cliEnv, 3600, now); err != nil {
		t.Fatal(err)
	}
	after, err := AcceptedKeys(f.dir, gatewayEnv, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 1 || after[0].Reveal() != goodKey2 {
		t.Fatalf("the gateway's accepted set widened to %d keys", len(after))
	}
}

// A2-01: PREVIOUS must also pass the entropy floor before it is accepted.
func TestAcceptedKeysIgnoresAWeakPrevious(t *testing.T) {
	f := newFixture(t)
	weak := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if !keyRE.MatchString(weak) || WeakKey(weak) == "" {
		t.Skipf("fixture assumption broken: weak key must be well-formed and weak")
	}
	f.write("LLMCTL_API_KEY="+goodKey+"\nLLMCTL_API_KEY_PREVIOUS="+weak+"\nLLMCTL_API_KEY_PREVIOUS_EXPIRES=99999999999\n", 0o600)
	ks, err := AcceptedKeys(f.dir, Environ{}, time.Unix(1, 0))
	if err != nil || len(ks) != 1 || ks[0].Reveal() != goodKey {
		t.Fatalf("a weak PREVIOUS was accepted: %d keys, err %v", len(ks), err)
	}
}

// A2-02: an environment-sourced key must not depend on the health of the .env file.
func TestAcceptedKeysWithEnvKeyNeverReadsTheEnvFile(t *testing.T) {
	f := newFixture(t)
	target := f.dir + "/elsewhere"
	if err := os.WriteFile(target, []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, f.file); err != nil { // a symlinked .env: ReadEnvFile refuses it
		t.Fatal(err)
	}
	ks, err := AcceptedKeys(f.dir, Environ{"LLMCTL_API_KEY": goodKey2}, time.Unix(1, 0))
	if err != nil || len(ks) != 1 || ks[0].Reveal() != goodKey2 {
		t.Fatalf("env key must keep working with an unusable .env: %d keys, err %v", len(ks), err)
	}
}

// A3-T2: revocation by editing the key out of .env. With no LLMCTL_API_KEY anywhere (source "none") an
// unexpired PREVIOUS left in the file must NOT be accepted on its own: PREVIOUS is only ever an
// overlap for a file-sourced current key. Decided semantics: removing the current key revokes; the
// operator gets no key accepted (the gateway start refuses, a running one fails closed after the
// stale grace), never "PREVIOUS alone".
func TestRevokedKeyWithAnUnexpiredPreviousAcceptsNothing(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY_PREVIOUS="+goodKey2+"\nLLMCTL_API_KEY_PREVIOUS_EXPIRES=99999999999\n", 0o600)
	res, err := Resolve(f.dir, Environ{}, false)
	if err != nil || res.Source != "none" {
		t.Fatalf("fixture: expected source none, got %q (%v)", res.Source, err)
	}
	ks, err := AcceptedKeys(f.dir, Environ{}, time.Unix(1, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(ks) != 0 {
		t.Fatalf("PREVIOUS alone was accepted after the current key was removed: %d keys", len(ks))
	}
	if KeyMatches(goodKey2, ks) {
		t.Fatal("the previous key still authenticates after revocation")
	}
}

// A3-03: a rotation run from a shell cannot know the environment of the running gateway. The output
// must always say that a gateway taking LLMCTL_API_KEY from ITS OWN environment (service unit,
// supervisor) is not affected, and how to revoke that key - with or without --grace, with or
// without LLMCTL_API_KEY in the CLI's own environment.
func TestRotateAlwaysStatesThatAnEnvironmentSourcedGatewayIsUnaffected(t *testing.T) {
	for name, env := range map[string]Environ{"cli without env key": {}, "cli with env key": {"LLMCTL_API_KEY": goodKey}} {
		for _, args := range [][]string{{"rotate"}, {"rotate", "--grace", "600"}} {
			f := newFixture(t)
			f.write("LLMCTL_API_KEY="+goodKey2+"\n", 0o600)
			r := runCLI(f.dir, env, args...)
			if r.rc != 0 {
				t.Fatalf("%s %v: rc=%d %s", name, args, r.rc, r.err)
			}
			for _, want := range []string{
				"does not affect a gateway that takes LLMCTL_API_KEY from its own environment",
				"to revoke that key, change or unset LLMCTL_API_KEY where the gateway gets it and restart the gateway",
			} {
				if !strings.Contains(r.out, want) {
					t.Errorf("%s %v: output lacks %q:\n%s", name, args, want, r.out)
				}
			}
		}
	}
}
