package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"runtime"
	"time"

	twoserivces "github.com/DKW2/MuCache_Extended/internal/twoservices"
	"github.com/DKW2/MuCache_Extended/pkg/common"
	"github.com/DKW2/MuCache_Extended/pkg/flame"
	"github.com/DKW2/MuCache_Extended/pkg/state"
	"github.com/DKW2/MuCache_Extended/pkg/wrappers"
	"github.com/golang/glog"
	//"flag"
	//_ "net/http/pprof"
)

var MaxProcs = 8

func heartbeat(w http.ResponseWriter, r *http.Request) {
	_, err := w.Write([]byte("Heartbeat\n"))
	if err != nil {
		return
	}
}

func read(ctx context.Context, req *twoserivces.ReadRequest) *twoserivces.ReadResponse {
	//req.K += 1
	start := time.Now() // log arrival timestamp
	v, err := state.GetState[int](ctx, fmt.Sprint(req.K))
	glog.Infof("[backend] GetState took %v", time.Since(start))
	if err != nil {
		v = 0
	}
	resp := twoserivces.ReadResponse{V: v}
	return &resp
}

func write(ctx context.Context, req *twoserivces.WriteRequest) *string {
	state.SetState(ctx, fmt.Sprint(req.K), req.V)
	resp := "OK"
	return &resp
}

func bigRead(ctx context.Context, req *twoserivces.ReadBulkRequest) *twoserivces.ReadBulkResponse {
	vs := make([]int, len(req.Ks))
	v, err := state.GetState[int](ctx, fmt.Sprint(req.Ks[0]))
	if err != nil {
		v = 0
	}
	for i := 0; i < len(req.Ks); i++ {
		vs[i] = v
	}
	resp := twoserivces.ReadBulkResponse{Vs: vs}
	return &resp
}

// readFlame / writeFlame are context-free handlers for flame mode.
func readFlame(req twoserivces.ReadRequest) twoserivces.ReadResponse {
	return *read(context.Background(), &req)
}
func writeFlame(req twoserivces.WriteRequest) string {
	return *write(context.Background(), &req)
}
func bigReadFlame(req twoserivces.ReadBulkRequest) twoserivces.ReadBulkResponse {
	return *bigRead(context.Background(), &req)
}

func main() {
	// flag.Set("logtostderr", "true")         // Ensure glog logs go to stderr
	// flag.Set("stderrthreshold", "INFO")     // Change to "ERROR" if you want only errors
	// flag.Parse()

	prev := runtime.GOMAXPROCS(MaxProcs)
	fmt.Printf("Set GOMAXPROCS to %d (was %d before)\n", MaxProcs, prev)

	if common.FLAME {
		flame.StartServer(flame.HandlerRegistry{
			"ro_read":  flame.WrapHandler(readFlame),
			"write":    flame.WrapHandler(writeFlame),
			"big_read": flame.WrapHandler(bigReadFlame),
		})
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "3005"
	}
	http.HandleFunc("/heartbeat", heartbeat)
	http.HandleFunc("/ro_read", wrappers.ROWrapper[twoserivces.ReadRequest, twoserivces.ReadResponse](read))
	http.HandleFunc("/write", wrappers.NonROWrapper[twoserivces.WriteRequest, string](write))
	http.HandleFunc("/big_read", wrappers.ROWrapper[twoserivces.ReadBulkRequest, twoserivces.ReadBulkResponse](bigRead))
	fmt.Printf("backend listening on :%s\n", port)
	err := http.ListenAndServe(":"+port, nil)
	if err != nil {
		panic(err)
	}
}
