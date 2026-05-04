// Package latency provides lightweight latency tracking with periodic summaries.
// Uses atomic counters — safe for concurrent use with near-zero overhead.
//
// Usage:
//
//	start := time.Now()
//	// ... operation ...
//	latency.Record("redis_get", time.Since(start))
//
// Every ReportInterval seconds, a summary is printed to stderr.
package latency

import (
	"fmt"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const ReportInterval = 5 * time.Second

type bucket struct {
	sumNs atomic.Int64
	count atomic.Int64
}

var (
	mu      sync.RWMutex
	buckets = make(map[string]*bucket)
)

func getBucket(name string) *bucket {
	mu.RLock()
	b, ok := buckets[name]
	mu.RUnlock()
	if ok {
		return b
	}
	mu.Lock()
	defer mu.Unlock()
	if b, ok = buckets[name]; ok {
		return b
	}
	b = &bucket{}
	buckets[name] = b
	return b
}

// Record adds a latency sample for the named operation.
func Record(name string, d time.Duration) {
	b := getBucket(name)
	b.sumNs.Add(int64(d))
	b.count.Add(1)
}

// Snapshot returns and resets all counters.
func Snapshot() map[string][2]int64 {
	mu.RLock()
	defer mu.RUnlock()
	snap := make(map[string][2]int64, len(buckets))
	for name, b := range buckets {
		sum := b.sumNs.Swap(0)
		cnt := b.count.Swap(0)
		if cnt > 0 {
			snap[name] = [2]int64{sum, cnt}
		}
	}
	return snap
}

func init() {
	if os.Getenv("LATENCY_REPORT") == "0" {
		return
	}
	go reporter()
}

func reporter() {
	ticker := time.NewTicker(ReportInterval)
	defer ticker.Stop()
	for range ticker.C {
		snap := Snapshot()
		if len(snap) == 0 {
			continue
		}
		names := make([]string, 0, len(snap))
		for n := range snap {
			names = append(names, n)
		}
		sort.Strings(names)

		fmt.Fprintf(os.Stderr, "\n=== LATENCY REPORT (%s) ===\n", time.Now().Format("15:04:05"))
		for _, name := range names {
			s := snap[name]
			sum, cnt := s[0], s[1]
			avgUs := float64(sum) / float64(cnt) / 1000.0
			totalMs := float64(sum) / 1e6
			fmt.Fprintf(os.Stderr, "  %-30s  cnt=%-8d  avg=%-10.1fµs  total=%.1fms\n",
				name, cnt, avgUs, totalMs)
		}
		fmt.Fprintf(os.Stderr, "===========================\n\n")
	}
}
