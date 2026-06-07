# Jenkins + Vault + Helm Lab on macOS Apple Silicon

Objective: practice a realistic workflow where Jenkins retrieves a secret from Vault, then deploys a Python application to Kubernetes with Helm.

This lab is designed for a MacBook Air M3 with Docker Desktop. It uses Vault in `dev` mode for learning only: this mode is insecure and loses data when the pod restarts.

## Architecture

```text
GitHub repository
   |
   v
Jenkins controller in kind
   |
   v
Kubernetes Jenkins agent with helm + kubectl + vault
   |
   +--> Vault dev server in kind
   |
   +--> Helm upgrade/install
           |
           v
        Python application in kind
```

Important point: Jenkins will not build the Docker image in this lab. Building Docker images from a Jenkins pod requires Docker-in-Docker, Kaniko, BuildKit, or a registry. To keep the lab reliable on macOS, the application image and the CI agent image are built locally, then loaded into kind with `kind load docker-image`.

## Prerequisites

Install Docker Desktop, then verify that it is running:

```bash
docker version
docker info
```

Install the local tools:

```bash
brew install kind kubectl helm git
```

Verify:

```bash
kind version
kubectl version --client
helm version
git --version
```

Docker Desktop recommendation for this lab: allocate 6 to 8 GB of memory if possible.

## 1. Create the kind cluster

```bash
kind create cluster --name devops-lab --wait 120s
kubectl cluster-info --context kind-devops-lab
kubectl get nodes
```

The node must be `Ready`.

## 2. Install Vault in dev mode

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set='server.dev.enabled=true' \
  --set='server.dev.devRootToken=root' \
  --wait \
  --timeout 5m
```

Verify:

```bash
kubectl get pods -n vault
kubectl -n vault exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status'
```

Optional UI access, in a separate terminal:

```bash
kubectl -n vault port-forward svc/vault 8200:8200
```

Then open `http://localhost:8200` and sign in with the `root` token.

## 3. Create the Vault secret and Kubernetes authentication

Create an application secret in Vault:

```bash
kubectl -n vault exec vault-0 -- sh -c '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault kv put secret/python-app \
  db_user=admin \
  db_password=SuperSecret123
'
```

Allow Vault to use the Kubernetes `TokenReview` API:

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault
  namespace: vault
EOF
```

Configure Vault to accept connections from the Jenkins service account:

```bash
kubectl -n vault exec vault-0 -- sh -c '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault auth enable kubernetes || true

vault write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"

vault policy write jenkins-python-app - <<EOF
path "secret/data/python-app" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/jenkins \
  bound_service_account_names=jenkins \
  bound_service_account_namespaces=jenkins \
  policies=jenkins-python-app \
  ttl=1h
'
```

## 4. Install Jenkins in kind

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update

helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --create-namespace \
  --wait \
  --timeout 10m
```

Retrieve the admin password:

```bash
kubectl get secret jenkins -n jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 --decode
echo
```

Jenkins access, in a separate terminal:

```bash
kubectl -n jenkins port-forward svc/jenkins 8080:8080
```

Open `http://localhost:8080`, user `admin`, with the password retrieved above.

## 5. Allow Jenkins to deploy into `apps`

```bash
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -
```

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-deployer
  namespace: apps
rules:
- apiGroups: [""]
  resources: ["configmaps", "pods", "secrets", "services"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-deployer
  namespace: apps
subjects:
- kind: ServiceAccount
  name: jenkins
  namespace: jenkins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-deployer
EOF
```

## 6. Create the local project

```bash
mkdir -p python-vault-lab/app
cd python-vault-lab
```

Create the Python application:

```bash
cat > app/app.py <<'EOF'
import os

from flask import Flask

app = Flask(__name__)


@app.route("/")
def index():
    db_user = os.getenv("DB_USER", "missing")
    password_present = "yes" if os.getenv("DB_PASSWORD") else "no"
    return f"DB_USER={db_user}\nDB_PASSWORD_PRESENT={password_present}\n"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF
```

```bash
cat > app/requirements.txt <<'EOF'
Flask>=3,<4
EOF
```

```bash
cat > app/Dockerfile <<'EOF'
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080
CMD ["python", "app.py"]
EOF
```

Build and load the image into kind:

```bash
docker build -t python-vault-lab:v1 ./app
kind load docker-image python-vault-lab:v1 --name devops-lab
```

## 7. Create the Helm chart

```bash
mkdir -p chart/python-app/templates
```

```bash
cat > chart/python-app/Chart.yaml <<'EOF'
apiVersion: v2
name: python-app
description: Lab app deployed by Jenkins with secrets from Vault
type: application
version: 0.1.0
appVersion: "v1"
EOF
```

```bash
cat > chart/python-app/values.yaml <<'EOF'
image:
  repository: python-vault-lab
  tag: v1
  pullPolicy: IfNotPresent

service:
  port: 8080

secrets:
  dbUser: ""
  dbPassword: ""
EOF
```

```bash
cat > chart/python-app/templates/secret.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: python-app-secrets
type: Opaque
stringData:
  DB_USER: {{ required "secrets.dbUser is required" .Values.secrets.dbUser | quote }}
  DB_PASSWORD: {{ required "secrets.dbPassword is required" .Values.secrets.dbPassword | quote }}
EOF
```

```bash
cat > chart/python-app/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: python-app
  template:
    metadata:
      labels:
        app: python-app
    spec:
      containers:
      - name: python-app
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: 8080
        envFrom:
        - secretRef:
            name: python-app-secrets
EOF
```

```bash
cat > chart/python-app/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: python-app
spec:
  selector:
    app: python-app
  ports:
  - name: http
    port: {{ .Values.service.port }}
    targetPort: 8080
EOF
```

Test the chart locally:

```bash
helm lint ./chart/python-app \
  --set-string secrets.dbUser=test \
  --set-string secrets.dbPassword=test

helm template python-app ./chart/python-app \
  --set-string secrets.dbUser=test \
  --set-string secrets.dbPassword=test
```

Optional manual deployment to verify the image and chart before Jenkins:

```bash
helm upgrade --install python-app ./chart/python-app \
  --namespace apps \
  --create-namespace \
  --set-string secrets.dbUser=manual \
  --set-string secrets.dbPassword=manual-password

kubectl -n apps rollout status deploy/python-app --timeout=120s
kubectl -n apps port-forward svc/python-app 8081:8080
```

In another terminal:

```bash
curl http://localhost:8081
```

Expected result:

```text
DB_USER=manual
DB_PASSWORD_PRESENT=yes
```

You can then let Jenkins replace this deployment, or delete it:

```bash
helm uninstall python-app -n apps
```

## 8. Create the Jenkins agent image

This image contains the tools used by the Jenkins agent: `git`, `helm`, `kubectl`, and `vault`.

```bash
mkdir -p ci
```

```bash
cat > ci/Dockerfile <<'EOF'
FROM alpine:3.22

ARG TARGETARCH
ARG HELM_VERSION=v3.19.0
ARG KUBECTL_VERSION=v1.34.5
ARG VAULT_VERSION=1.21.2

RUN apk add --no-cache bash ca-certificates curl git openssh-client tar unzip

RUN set -eux; \
    ARCH="${TARGETARCH:-$(uname -m)}"; \
    case "$ARCH" in \
      amd64|x86_64) ARCH=amd64 ;; \
      arm64|aarch64) ARCH=arm64 ;; \
      *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"; \
    tar -xzf /tmp/helm.tgz -C /tmp; \
    mv "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    curl -fsSLo /tmp/vault.zip "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${ARCH}.zip"; \
    unzip /tmp/vault.zip -d /usr/local/bin; \
    chmod +x /usr/local/bin/helm /usr/local/bin/kubectl /usr/local/bin/vault; \
    helm version; \
    kubectl version --client=true; \
    vault version; \
    rm -rf /tmp/*

WORKDIR /home/jenkins/agent
CMD ["bash"]
EOF
```

Build and load the image into kind:

```bash
docker build -t jenkins-ci-toolbox:v1 ./ci
kind load docker-image jenkins-ci-toolbox:v1 --name devops-lab
```

## 9. Create the Jenkinsfile

```bash
cat > Jenkinsfile <<'EOF'
pipeline {
  agent {
    kubernetes {
      defaultContainer 'ci'
      yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins
  containers:
  - name: ci
    image: jenkins-ci-toolbox:v1
    imagePullPolicy: IfNotPresent
    command:
    - cat
    tty: true
'''
    }
  }

  options {
    skipDefaultCheckout(true)
  }

  environment {
    APP_NAMESPACE = 'apps'
    VAULT_ADDR = 'http://vault.vault.svc.cluster.local:8200'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Check tools') {
      steps {
        sh '''
          set -eu
          git --version
          helm version
          kubectl version --client=true
          vault version
        '''
      }
    }

    stage('Read secrets from Vault') {
      steps {
        sh '''
          set +x
          JWT="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
          VAULT_TOKEN="$(vault write -field=token auth/kubernetes/login role=jenkins jwt="$JWT")"
          export VAULT_TOKEN

          vault kv get -field=db_user secret/python-app | tr -d '\\n' > .db_user
          vault kv get -field=db_password secret/python-app | tr -d '\\n' > .db_password
          chmod 600 .db_user .db_password
          set -x

          echo "Secrets fetched from Vault and written to temporary files for Helm."
        '''
      }
    }

    stage('Deploy with Helm') {
      steps {
        sh '''
          set -eu
          helm upgrade --install python-app ./chart/python-app \
            --namespace "$APP_NAMESPACE" \
            --create-namespace \
            --set-file secrets.dbUser=.db_user \
            --set-file secrets.dbPassword=.db_password

          kubectl -n "$APP_NAMESPACE" rollout status deploy/python-app --timeout=120s
        '''
      }
    }

    stage('Smoke test') {
      steps {
        sh '''
          set -eu
          kubectl -n "$APP_NAMESPACE" run smoke-test \
            --rm \
            -i \
            --restart=Never \
            --image=python-vault-lab:v1 \
            --image-pull-policy=IfNotPresent \
            --command -- python -c 'import urllib.request; print(urllib.request.urlopen("http://python-app:8080/").read().decode())'
        '''
      }
    }
  }

  post {
    always {
      sh 'rm -f .db_user .db_password'
    }
  }
}
EOF
```

## 10. Publish the project to GitHub

Jenkins runs inside kind, so it cannot directly see the files on your Mac. The simplest option is to push this directory to a GitHub repository.

```bash
git init
git add .
git commit -m "Initial Jenkins Vault Helm lab"
git branch -M main
```

Then create an empty GitHub repository and push:

```bash
git remote add origin git@github.com:<your-user>/python-vault-lab.git
git push -u origin main
```

If the repository is private, add a GitHub credential in Jenkins. For a first run, a public repository keeps the lab simpler.

## 11. Create the Jenkins job

In Jenkins:

1. `New Item`
2. Name: `python-vault-lab`
3. Type: `Pipeline`
4. `Definition`: `Pipeline script from SCM`
5. `SCM`: `Git`
6. `Repository URL`: GitHub repository URL
7. `Branch Specifier`: `*/main`
8. `Script Path`: `Jenkinsfile`
9. Save, then run `Build Now`

The build must:

1. create a Kubernetes agent with the `jenkins-ci-toolbox:v1` image
2. authenticate to Vault with the `jenkins` service account
3. read `secret/python-app`
4. deploy the Helm chart into the `apps` namespace
5. run an HTTP smoke test inside the cluster

## 12. Verify the result

```bash
kubectl -n apps get pods,svc,secrets
kubectl -n apps rollout status deploy/python-app
```

Local access:

```bash
kubectl -n apps port-forward svc/python-app 8081:8080
```

In another terminal:

```bash
curl http://localhost:8081
```

Expected result after Jenkins:

```text
DB_USER=admin
DB_PASSWORD_PRESENT=yes
```

## Key Points

- Jenkins does not store `db_password` in the Git chart.
- Vault only allows the Kubernetes service account `jenkins` in the `jenkins` namespace.
- The chart creates a Kubernetes `Secret` and injects it as environment variables.
- `kind load docker-image` avoids using a registry for this local lab.
- `imagePullPolicy: IfNotPresent` is required for images loaded locally into kind.

## Intentional Lab Limits

- Vault `dev` is not persistent and must never be used in production.
- Injecting secrets through Helm is acceptable to understand the workflow, but in production you should instead study Vault Agent Injector, Vault CSI Provider, or External Secrets Operator.
- The Docker build runs on macOS, not in Jenkins. To go further, add a local registry, Kaniko, or BuildKit.
- The password ends up in a Kubernetes `Secret`. This is better than storing a secret in Git, but it is not equivalent to direct Vault consumption by the application.

## Cleanup

Delete the whole lab:

```bash
kind delete cluster --name devops-lab
```

## Official References

- kind quick start and image loading: https://kind.sigs.k8s.io/docs/user/quick-start/
- Jenkins Helm chart: https://charts.jenkins.io/
- Jenkins on Kubernetes: https://www.jenkins.io/doc/book/installing/kubernetes/
- Vault Helm chart: https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm/configuration
- Vault Kubernetes auth method: https://developer.hashicorp.com/vault/docs/auth/kubernetes
