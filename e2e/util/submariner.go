// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package util

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// RefreshSubmarinerTunnel restarts Submariner data-path pods on both
// clusters to rebuild globalnet iptables and DNS state. On docker-driver
// minikube (shared kernel), these degrade over time and cause long-lived
// TLS connections (VolSync rsync-tls) to stall.
//
// Always restarts unconditionally — "subctl show connections" can report
// "connected" while globalnet iptables are broken, so a probe-gated
// approach produces false negatives.
//
// Enabled by setting E2E_REFRESH_TUNNEL=true.
func RefreshSubmarinerTunnel(ctx context.Context) error {
	if os.Getenv("E2E_REFRESH_TUNNEL") != "true" {
		return nil
	}

	clusters := []string{"dr1", "dr2"}
	namespace := "submariner-operator"
	apps := []string{"submariner-gateway", "submariner-routeagent", "submariner-lighthouse-agent", "submariner-lighthouse-coredns"}

	for _, cluster := range clusters {
		for _, app := range apps {
			_ = RunCommand(ctx, "kubectl", "--context", cluster, "-n", namespace, "delete", "pods", "-l", "app="+app, "--wait=false")
		}
	}

	for _, cluster := range clusters {
		if err := RunCommand(ctx, "kubectl", "--context", cluster, "-n", namespace, "wait", "pod", "-l", "app=submariner-gateway", "--for=condition=Ready", "--timeout=120s"); err != nil {
			return fmt.Errorf("gateway not ready on %s: %w", cluster, err)
		}

		_ = RunCommand(ctx, "kubectl", "--context", cluster, "-n", namespace, "rollout", "status", "deploy/submariner-lighthouse-agent", "--timeout=120s")
		_ = RunCommand(ctx, "kubectl", "--context", cluster, "-n", namespace, "rollout", "status", "deploy/submariner-lighthouse-coredns", "--timeout=120s")
	}

	for i := range 24 {
		out, err := commandOutput(ctx, "subctl", "show", "connections", "--context", clusters[0])
		if err == nil && strings.Contains(out, "connected") {
			fmt.Println("Submariner tunnel re-established after restart")
			return nil
		}

		if i < 23 {
			if err := Sleep(ctx, 5*time.Second); err != nil {
				return err
			}
		}
	}

	return fmt.Errorf("submariner tunnel not connected after restart")
}

func commandOutput(ctx context.Context, command string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, command, args...)
	cmd.SysProcAttr = &runInBackground
	out, err := cmd.Output()

	return string(out), err
}
