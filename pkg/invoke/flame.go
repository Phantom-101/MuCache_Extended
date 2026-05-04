//go:build flame
// +build flame

package invoke

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/DKW2/MuCache_Extended/pkg/flame"
	"github.com/DKW2/MuCache_Extended/pkg/latency"
)

// flameClients maps service name → RpcClient.
// Built lazily from FLAME_CHANNELS_FILE (format: "appname channelname" per line).
var (
	flameClients     map[string]*flame.RpcClient
	flameClientsOnce sync.Once
)

func getFlameClients() map[string]*flame.RpcClient {
	flameClientsOnce.Do(func() {
		flameClients = make(map[string]*flame.RpcClient)

		// Legacy single-downstream (chain benchmark)
		if single := os.Getenv("FLAME_DOWNSTREAM"); single != "" {
			callee := os.Getenv("FLAME_DOWNSTREAM_APP")
			if callee == "" {
				callee = "_default"
			}
			c, err := flame.NewRpcClient(single)
			if err != nil {
				panic(fmt.Sprintf("flame RpcClient(%q): %v", single, err))
			}
			flameClients[callee] = c
		}

		// Multi-downstream (hotel, social)
		path := os.Getenv("FLAME_CHANNELS_FILE")
		if path == "" {
			return
		}
		f, err := os.Open(path)
		if err != nil {
			panic(fmt.Sprintf("FLAME_CHANNELS_FILE: %v", err))
		}
		defer f.Close()
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.SplitN(line, " ", 2)
			if len(parts) != 2 {
				continue
			}
			app := strings.TrimSpace(parts[0])
			channel := strings.TrimSpace(parts[1])
			if _, exists := flameClients[app]; exists {
				continue // already registered (e.g. from FLAME_DOWNSTREAM)
			}
			c, err := flame.NewRpcClient(channel)
			if err != nil {
				panic(fmt.Sprintf("flame RpcClient(%q→%q): %v", app, channel, err))
			}
			flameClients[app] = c
		}
	})
	return flameClients
}

// flameInvoke sends the request over shared memory and returns the raw response bytes.
func flameInvoke(app string, method string, body []byte) []byte {
	clients := getFlameClients()
	c := clients[app]
	if c == nil {
		c = clients["_default"]
	}
	if c == nil {
		panic(fmt.Sprintf("flameInvoke: no flame channel for app %q", app))
	}
	t0 := time.Now()
	resp, err := c.Call(method, body)
	latency.Record("flame_rpc_call", time.Since(t0))
	if err != nil {
		panic(fmt.Sprintf("flameInvoke(%s/%s): %v", app, method, err))
	}
	return resp
}
