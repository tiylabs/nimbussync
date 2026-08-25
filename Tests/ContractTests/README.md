# Cloudreve Contract Tests

The real-server probe is opt-in and never stores response bodies or credentials.

```sh
export CLOUDREVE_ORIGIN=https://cloudreve.example.test
export CLOUDREVE_ACCESS_TOKEN='from a local secret manager'
export CLOUDREVE_CONTRACT_PROBE=1
Scripts/contract-tests/run-cloudreve-probe.sh
```

The probe currently verifies HTTPS origin handling and authenticated account
identity. The mutation, upload-provider, refresh-rotation and File Provider
rows stay `unverified` until a controlled Cloudreve environment and signed
Finder harness produce evidence. They must not be promoted by editing the
report alone.

