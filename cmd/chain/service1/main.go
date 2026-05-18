package main

import (
	//"flag"
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"runtime"
	"time"

	"github.com/DKW2/MuCache_Extended/internal/loadcm"
	twoserivces "github.com/DKW2/MuCache_Extended/internal/twoservices"
	"github.com/DKW2/MuCache_Extended/pkg/invoke"
	"github.com/DKW2/MuCache_Extended/pkg/wrappers"
)

var Callee = "service2"
var MaxProcs = 8

func heartbeat(w http.ResponseWriter, r *http.Request) {
	_, err := w.Write([]byte("Heartbeat\n"))
	if err != nil {
		return
	}
}

func read(ctx context.Context, req *twoserivces.ReadRequest) *twoserivces.ReadResponse {
	resp := invoke.Invoke[twoserivces.ReadResponse](ctx, Callee, "ro_read", req)
	return &resp
}

func write(ctx context.Context, req *twoserivces.WriteRequest) *string {
	resp := invoke.Invoke[string](ctx, Callee, "write", req)
	return &resp
}

func hitormiss(ctx context.Context, req *twoserivces.HitOrMissRequest) *string {
	arrivalTime := time.Now()
	startTime := time.Now()
	dice := rand.Float32()
	if dice < req.HitRate {
		invoke.InvokeHit(ctx, Callee, "ro_hitormiss", req)
	} else {
		invoke.InvokeMiss[string](ctx, Callee, "ro_hitormiss", req)
	}
	endTime := time.Now()

	// Logging
	fmt.Printf("[%s] QueueTime=%v, InvokeTime=%v, TotalTime=%v\n",
		Callee,
		startTime.Sub(arrivalTime), // Queue time (very small if no queuing in Go scheduler)
		endTime.Sub(startTime),     // Processing time (Invoke)
		endTime.Sub(arrivalTime),   // Total handler time
	)
	resp := "OK"
	return &resp
}

func invalidationExperiment(ctx context.Context, req *loadcm.InvalidationExperimentRequest) *string {
	// Start running the zmqfeeder
	fmt.Printf("Starting experiment for: %v \n", req.Times)
	go twoserivces.InvalidationExperiment(req.Times, req.Timeout, Callee, "ro_read", "backend", "write")
	resp := "OK"
	return &resp
}

func bigRead(ctx context.Context, req *twoserivces.ReadBulkRequest) *twoserivces.ReadBulkResponse {
	resp := invoke.Invoke[twoserivces.ReadBulkResponse](ctx, Callee, "big_read", req)
	return &resp
}

func main() {
	// flag.Set("logtostderr", "true")         // Ensure glog logs go to stderr
	// flag.Set("stderrthreshold", "INFO")     // Change to "ERROR" if you want only errors
	// flag.Parse()

	fmt.Println(runtime.GOMAXPROCS(MaxProcs))

	// service1 receives HTTP from client (oha) — no flame server needed.
	// It sends downstream to service2 via flame (FLAME_DOWNSTREAM).

	port := os.Getenv("PORT")
	if port == "" {
		port = "3001"
	}
	http.HandleFunc("/heartbeat", heartbeat)
	http.HandleFunc("/ro_read", wrappers.ROWrapper[twoserivces.ReadRequest, twoserivces.ReadResponse](read))
	http.HandleFunc("/write", wrappers.NonROWrapper[twoserivces.WriteRequest, string](write))
	http.HandleFunc("/ro_hitormiss", wrappers.ROWrapper[twoserivces.HitOrMissRequest, string](hitormiss))
	http.HandleFunc("/invalidation_experiment", wrappers.NonROWrapper[loadcm.InvalidationExperimentRequest, string](invalidationExperiment))
	http.HandleFunc("/big_read", wrappers.ROWrapper[twoserivces.ReadBulkRequest, twoserivces.ReadBulkResponse](bigRead))
	fmt.Printf("service1 listening on :%s\n", port)
	err := http.ListenAndServe(":"+port, nil)
	if err != nil {
		panic(err)
	}
}
