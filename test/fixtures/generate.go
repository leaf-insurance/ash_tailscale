// Regenerate: go run test/fixtures/generate.go > test/fixtures/go_q.json
// Uses the same mime.QEncoding.Encode("utf-8", value) call as Tailscale Serve.
package main

import (
	"encoding/json"
	"mime"
	"os"
	"strings"
)

func main() {
	values := []string{
		"Alice_Smith",
		"René _李",
		strings.Repeat("世界_ ", 20),
		"{\"example.com/cap/报告\":[{\"text\":\"" + strings.Repeat("世界_ ", 30) + "\",\"nested\":[null,true,{\"n\":12}]}],\"null\":null}",
	}
	fixtures := make([]map[string]string, 0, len(values))
	for _, value := range values {
		fixtures = append(fixtures, map[string]string{"value": value, "encoded": mime.QEncoding.Encode("utf-8", value)})
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(fixtures); err != nil {
		panic(err)
	}
}
