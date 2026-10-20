# Evidence

Every file here is the output of a command that ran against this repository, captured with
`tee`/redirect rather than retyped. Where something did not work, the failure is included.

| File | What it shows |
|---|---|
| `01-cluster.txt` | Node, pods, service, ingress, the three ClusterIssuers, both Certificates |
| `02-tls.txt` | HTTP redirect, TLS 1.3 handshake, `Verify return code: 0 (ok)`, the leaf's SAN |
| `03-concurrency.txt` | Request counts at three different loads, and the single-connection limitation behind them |
| `04-docker-traps.txt` | Four real failures — wrong netcat, missing PATH entry, no fortune data, read-only FIFO — plus the configuration that works |
| `05-scan.txt` | Trivy: 0 with `--ignore-unfixed`, 60 without, none of them fixable |
| `06-ps2-scripts.txt` | Both Problem Statement 2 scripts, including the breach, missing-process and TLS-failure paths |
| `07-cloud.txt` | The live k3s deployment: Let's Encrypt chain, public TLS verification, and the cluster it runs on |

## What is not here

Screenshots. A picture of a terminal is not evidence, it is a claim with better typeface.
These are the commands and their real output, so anyone can re-run them and diff.

No browser screenshot of the padlock either, for the same reason — `make ca` and
`curl --cacert` prove the chain. If you want the visual, the README explains how to import
the CA.

## Re-running

```bash
make cluster controllers image load deploy ca
bash scripts/system_health_monitor.sh
python3 scripts/app_health_checker.py --url https://wisecow.test --cacert docs/wisecow-ca.crt
```
