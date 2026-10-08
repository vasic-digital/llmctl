package gateway

import "time"

// sleepTick is the poll interval of throughput-mode slot waiting.
func sleepTick() { time.Sleep(5 * time.Millisecond) }
