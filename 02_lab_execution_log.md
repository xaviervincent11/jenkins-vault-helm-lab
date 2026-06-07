# Jenkins + Vault + Helm Lab Execution Log

Date: Sunday, June 7, 2026

Workspace: `/Users/xvincent/Documents/Amadeus/20260606_exp_Jenkins_vault_helm_chart/cyberark`

Project directory: `python-vault-lab/`

## Environment Check

- Python venv interpreter: `/Users/xvincent/x1/bin/python3`
- Python version: `Python 3.12.3`
- Docker Desktop: running and reachable after approving Docker socket access
- Docker client/server: `29.1.2`
- kind: `v0.31.0`
- kubectl client: `v1.35.1`
- Helm: `v4.1.4`

## Execution Notes

- Docker access initially failed inside the sandbox with permission denied on `/Users/xvincent/.docker/run/docker.sock`.
- Docker command escalation was approved, and `docker version` then succeeded.

## Steps

### 1. Local Validation

Status: completed.

Commands executed:

```bash
/Users/xvincent/x1/bin/python3 -m py_compile app/app.py
helm lint ./chart/python-app --set-string secrets.dbUser=test --set-string secrets.dbPassword=test
helm template python-app ./chart/python-app --set-string secrets.dbUser=test --set-string secrets.dbPassword=test
```

Result:

- Python syntax check passed.
- Helm lint passed.
- Helm template rendered the Secret, Service, and Deployment manifests successfully.

### 2. Build Local Docker Images

Status: completed.

Commands executed:

```bash
docker build -t python-vault-lab:v1 ./app
docker build -t jenkins-ci-toolbox:v1 ./ci
```

Result:

- Built `python-vault-lab:v1`.
- Built `jenkins-ci-toolbox:v1`.
- The toolbox image includes Helm `v3.19.0`, kubectl `v1.34.5`, and Vault `v1.21.2`.

### 3. Create kind Cluster

Status: completed.

Commands executed:

```bash
kind get clusters
kind create cluster --name devops-lab --wait 120s
kind load docker-image python-vault-lab:v1 --name devops-lab
kind load docker-image jenkins-ci-toolbox:v1 --name devops-lab
kubectl get nodes
```

Result:

- Existing kind cluster `kind` was detected and left untouched.
- Created a separate `devops-lab` kind cluster.
- Current kubectl context: `kind-devops-lab`.
- Node `devops-lab-control-plane` is `Ready` on Kubernetes `v1.35.0`.
- Loaded `python-vault-lab:v1` into kind, image ID `sha256:5e70ed018b1923768ff8724b0cdb880b979a537559cacc26d4cbea9b115f5141`.
- Loaded `jenkins-ci-toolbox:v1` into kind, image ID `sha256:4eade8894e1b04073e856abb6b007389f88745c354a53e5fa70f28e71a46c2ea`.

### 4. Install and Configure Vault

Status: completed.

Commands executed:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update hashicorp
helm upgrade --install vault hashicorp/vault --namespace vault --create-namespace --set=server.dev.enabled=true --set=server.dev.devRootToken=root --wait --timeout 5m
kubectl get pods -n vault
kubectl -n vault exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status'
kubectl apply -f k8s/vault-tokenreview-rbac.yaml
kubectl -n vault exec vault-0 -- sh -c 'vault kv put secret/python-app db_user=admin db_password=SuperSecret123'
kubectl -n vault exec vault-0 -- sh -c 'vault auth enable kubernetes ...'
kubectl -n vault exec vault-0 -- sh -c 'vault read auth/kubernetes/role/jenkins'
kubectl -n vault exec vault-0 -- sh -c 'vault kv get -field=db_user secret/python-app'
```

Result:

- Installed Vault release `vault` in namespace `vault`.
- Vault pod `vault-0` is `Running`.
- Vault status: initialized, unsealed, version `1.21.2`, storage type `inmem`.
- Created `secret/data/python-app` with `db_user=admin` and `db_password=SuperSecret123`.
- Applied `vault-tokenreview` ClusterRoleBinding.
- Enabled Vault Kubernetes auth at `kubernetes/`.
- Created Vault policy `jenkins-python-app`.
- Created Vault Kubernetes role `jenkins` bound to service account `jenkins` in namespace `jenkins`.
- Verified `secret/python-app` returns `db_user=admin`.

Note:

- `helm repo update` failed globally because an existing local Helm repository named `local-repo` points at `http://localhost:8082`, which is not running. This was not changed. `helm repo update hashicorp` succeeded and was sufficient for Vault.

### 5. Install and Configure Jenkins

Status: in progress.

### 6. Deploy and Validate the Application

Status: pending.

### 7. Jenkins Pipeline

Status: pending.
