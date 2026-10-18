package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/df-mc/go-nethernet"
	"github.com/df-mc/go-nethernet/endpoint"
)

// Follows the vanilla join flow: https probe, http probe, signed offer, then echoes on both channels.
func main() {
	if len(os.Args) != 4 {
		fail(fmt.Errorf("usage: interop host:port reliable-sizes unreliable-sizes"))
	}
	host := os.Args[1]

	probe := &http.Client{Timeout: 3 * time.Second}
	start := time.Now()
	if resp, err := probe.Get("https://" + host + "/v1/join"); err == nil {
		resp.Body.Close()
		fail(fmt.Errorf("https probe succeeded against a plaintext endpoint"))
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		fail(fmt.Errorf("https probe took %v to fail", elapsed))
	}
	resp, err := probe.Get("http://" + host + "/v1/join")
	if err != nil {
		fail(err)
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		fail(fmt.Errorf("GET /v1/join: %s", resp.Status))
	}

	key, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		fail(err)
	}
	identity, err := nethernet.GenerateServerIdentity(key, "https://authorization.franchise.minecraft-services.net/")
	if err != nil {
		fail(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	start = time.Now()
	conn, err := (nethernet.Dialer{DisableTrickleICE: true, Identity: identity}).DialContext(ctx, "http://"+host, endpoint.NewClient())
	if err != nil {
		fail(err)
	}
	defer conn.Close()
	fmt.Printf("connected in %dms\n", time.Since(start).Milliseconds())

	echo(conn, os.Args[2], nethernet.MessageReliabilityReliable)
	echo(conn, os.Args[3], nethernet.MessageReliabilityUnreliable)
	if _, err := conn.Write([]byte("ack")); err != nil {
		fail(err)
	}
	time.Sleep(100 * time.Millisecond)
}

func echo(conn *nethernet.Conn, sizes string, reliability nethernet.MessageReliability) {
	for _, text := range strings.Split(sizes, ",") {
		size, err := strconv.Atoi(text)
		if err != nil {
			fail(err)
		}
		data := make([]byte, size)
		for i := range data {
			data[i] = byte(i * 31)
		}
		if n, err := conn.Send(data, reliability); err != nil || n != len(data) {
			fail(fmt.Errorf("send %d bytes: %v", size, err))
		}
		received, err := conn.Receive(reliability)
		if err != nil {
			fail(err)
		}
		if !bytes.Equal(data, received) {
			fail(fmt.Errorf("echo of %d bytes differs", size))
		}
		fmt.Printf("echoed %d bytes\n", size)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
