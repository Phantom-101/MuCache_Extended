package main

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"runtime"

	twoserivces "github.com/DKW2/MuCache_Extended/internal/twoservices"
	"github.com/DKW2/MuCache_Extended/pkg/common"
	"github.com/DKW2/MuCache_Extended/pkg/flame"
	"github.com/DKW2/MuCache_Extended/pkg/invoke"
	"github.com/DKW2/MuCache_Extended/pkg/wrappers"
)

var Callee = "service4"
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
	dice := rand.Float32()
	if dice < req.HitRate {
		invoke.InvokeHit(ctx, Callee, "ro_hitormiss", req)
	} else {
		invoke.InvokeMiss[string](ctx, Callee, "ro_hitormiss", req)
	}
	resp := "OK"
	return &resp
}

func bigRead(ctx context.Context, req *twoserivces.ReadBulkRequest) *twoserivces.ReadBulkResponse {
	resp := invoke.Invoke[twoserivces.ReadBulkResponse](ctx, Callee, "big_read", req)
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
	fmt.Println(runtime.GOMAXPROCS(MaxProcs))

	if common.FLAME {
		flame.StartServer(flame.HandlerRegistry{
			"ro_read":  flame.WrapHandler(readFlame),
			"write":    flame.WrapHandler(writeFlame),
			"big_read": flame.WrapHandler(bigReadFlame),
		})
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "3003"
	}
	http.HandleFunc("/heartbeat", heartbeat)
	http.HandleFunc("/ro_read", wrappers.ROWrapper[twoserivces.ReadRequest, twoserivces.ReadResponse](read))
	http.HandleFunc("/write", wrappers.NonROWrapper[twoserivces.WriteRequest, string](write))
	http.HandleFunc("/ro_hitormiss", wrappers.ROWrapper[twoserivces.HitOrMissRequest, string](hitormiss))
	http.HandleFunc("/big_read", wrappers.ROWrapper[twoserivces.ReadBulkRequest, twoserivces.ReadBulkResponse](bigRead))
	fmt.Printf("service3 listening on :%s\n", port)
	err := http.ListenAndServe(":"+port, nil)
	if err != nil {
		panic(err)
	}
}
