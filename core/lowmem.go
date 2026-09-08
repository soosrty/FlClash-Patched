//go:build with_low_memory

package main

import "runtime/debug"

// The network extension gets a much smaller memory allowance than the host
// app. 32MB made the GC run flat out against the ceiling (wakeups kill at
// ~15s), while no limit at all overshot the ~50MB jetsam cap (kill at ~3s).
// 44MB leaves headroom below jetsam while giving the GC room to breathe.
const lowMemoryLimit = 44 * 1024 * 1024

func init() {
	debug.SetMemoryLimit(lowMemoryLimit)
}
