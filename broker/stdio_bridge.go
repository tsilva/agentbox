package main

import (
	"context"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

var errStreamClosed = errors.New("isolated broker stream unavailable")

// The attached byte stream is already point-to-point. net.Pipe supplies
// deadline and shutdown semantics even when the process handles are pipes.
func attachedStream(input io.ReadCloser, output io.WriteCloser) (net.Conn, <-chan struct{}) {
	conn, stream := net.Pipe()
	done := make(chan struct{})
	var once sync.Once
	stop := func() {
		once.Do(func() {
			close(done)
			_ = stream.Close()
			_ = output.Close()
			_ = input.Close()
		})
	}
	go func() {
		_, _ = io.Copy(stream, input)
		stop()
	}()
	go func() {
		_, _ = io.Copy(output, stream)
		stop()
	}()
	return conn, done
}

func streamProtocol() *http.Protocols {
	p := new(http.Protocols)
	p.SetUnencryptedHTTP2(true)
	return p
}

func attachedRelay(conn net.Conn) http.Handler {
	var used atomic.Bool
	transport := &http.Transport{
		Protocols: streamProtocol(), MaxConnsPerHost: 1,
		ResponseHeaderTimeout: 60 * time.Second,
		DialContext: func(_ context.Context, network, address string) (net.Conn, error) {
			if network != "tcp" || address != "attached-broker:80" ||
				!used.CompareAndSwap(false, true) {
				return nil, errStreamClosed
			}
			return conn, nil
		},
	}
	relay := &httputil.ReverseProxy{
		Transport: transport, FlushInterval: -1, ErrorLog: log.New(io.Discard, "", 0),
		Rewrite: func(request *httputil.ProxyRequest) {
			request.SetURL(&url.URL{Scheme: "http", Host: "attached-broker"})
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, "broker unavailable", http.StatusBadGateway)
		},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Reject non-origin-form requests before any parser or proxy can
		// reinterpret them as a different target or protocol.
		if r.URL.IsAbs() || r.URL.Host != "" || r.URL.RawPath != "" ||
			r.URL.ForceQuery || r.Header.Get("Upgrade") != "" ||
			r.Header.Get("Proxy-Authorization") != "" ||
			r.Method == http.MethodConnect {
			http.Error(w, "route denied", http.StatusForbidden)
			return
		}
		relay.ServeHTTP(w, r)
	})
}

func serveAttachedRelay(socket string, conn net.Conn, done <-chan struct{}) error {
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(socket)
	if err = os.Chmod(socket, 0600); err != nil {
		return err
	}
	go func() {
		<-done
		_ = listener.Close()
	}()
	err = serve(listener, attachedRelay(conn))
	if errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}
