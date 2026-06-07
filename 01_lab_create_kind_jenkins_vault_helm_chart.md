# Lab Jenkins + Vault + Helm sur macOS Apple Silicon

Objectif : pratiquer une chaîne réaliste où Jenkins récupère un secret dans Vault, puis déploie une application Python dans Kubernetes avec Helm.

Ce lab est prévu pour un MacBook Air M3 avec Docker Desktop. Il utilise Vault en mode `dev` uniquement pour apprendre : ce mode est non sécurisé et perd les données au redémarrage du pod.

## Architecture

```text
GitHub repository
   |
   v
Jenkins controller dans kind
   |
   v
Jenkins agent Kubernetes avec helm + kubectl + vault
   |
   +--> Vault dev server dans kind
   |
   +--> Helm upgrade/install
           |
           v
        Application Python dans kind
```

Point important : Jenkins ne construira pas l'image Docker dans ce lab. Construire Docker depuis un pod Jenkins nécessite Docker-in-Docker, Kaniko, BuildKit ou un registry. Pour garder le lab fiable sur macOS, l'image applicative et l'image d'agent CI sont construites localement puis chargées dans kind avec `kind load docker-image`.

## Prérequis

Installe Docker Desktop, puis vérifie qu'il tourne :

```bash
docker version
docker info
```

Installe les outils locaux :

```bash
brew install kind kubectl helm git
```

Vérifie :

```bash
kind version
kubectl version --client
helm version
git --version
```

Recommandation Docker Desktop pour ce lab : 6 à 8 Go de mémoire allouée si possible.

## 1. Créer le cluster kind

```bash
kind create cluster --name devops-lab --wait 120s
kubectl cluster-info --context kind-devops-lab
kubectl get nodes
```

Le noeud doit être `Ready`.

## 2. Installer Vault en mode dev

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

Vérifie :

```bash
kubectl get pods -n vault
kubectl -n vault exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status'
```

Accès UI optionnel, dans un terminal séparé :

```bash
kubectl -n vault port-forward svc/vault 8200:8200
```

Puis ouvre `http://localhost:8200` et connecte-toi avec le token `root`.

## 3. Créer le secret Vault et l'authentification Kubernetes

Crée un secret applicatif dans Vault :

```bash
kubectl -n vault exec vault-0 -- sh -c '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault kv put secret/python-app \
  db_user=admin \
  db_password=SuperSecret123
'
```

Autorise Vault à utiliser l'API Kubernetes `TokenReview` :

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

Configure Vault pour accepter les connexions du service account Jenkins :

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

## 4. Installer Jenkins dans kind

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update

helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --create-namespace \
  --wait \
  --timeout 10m
```

Récupère le mot de passe admin :

```bash
kubectl get secret jenkins -n jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 --decode
echo
```

Accès Jenkins, dans un terminal séparé :

```bash
kubectl -n jenkins port-forward svc/jenkins 8080:8080
```

Ouvre `http://localhost:8080`, utilisateur `admin`, mot de passe récupéré ci-dessus.

## 5. Donner à Jenkins le droit de déployer dans `apps`

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

## 6. Créer le projet local

```bash
mkdir -p python-vault-lab/app
cd python-vault-lab
```

Crée l'application Python :

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

Construis et charge l'image dans kind :

```bash
docker build -t python-vault-lab:v1 ./app
kind load docker-image python-vault-lab:v1 --name devops-lab
```

## 7. Créer le Helm chart

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

Teste le chart localement :

```bash
helm lint ./chart/python-app \
  --set-string secrets.dbUser=test \
  --set-string secrets.dbPassword=test

helm template python-app ./chart/python-app \
  --set-string secrets.dbUser=test \
  --set-string secrets.dbPassword=test
```

Déploiement manuel optionnel pour vérifier l'image et le chart avant Jenkins :

```bash
helm upgrade --install python-app ./chart/python-app \
  --namespace apps \
  --create-namespace \
  --set-string secrets.dbUser=manual \
  --set-string secrets.dbPassword=manual-password

kubectl -n apps rollout status deploy/python-app --timeout=120s
kubectl -n apps port-forward svc/python-app 8081:8080
```

Dans un autre terminal :

```bash
curl http://localhost:8081
```

Résultat attendu :

```text
DB_USER=manual
DB_PASSWORD_PRESENT=yes
```

Tu peux ensuite laisser Jenkins remplacer ce déploiement, ou le supprimer :

```bash
helm uninstall python-app -n apps
```

## 8. Créer l'image d'agent Jenkins

Cette image contient les outils utilisés par l'agent Jenkins : `git`, `helm`, `kubectl` et `vault`.

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

Construis et charge l'image dans kind :

```bash
docker build -t jenkins-ci-toolbox:v1 ./ci
kind load docker-image jenkins-ci-toolbox:v1 --name devops-lab
```

## 9. Créer le Jenkinsfile

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

## 10. Publier le projet dans GitHub

Jenkins tourne dans kind, donc il ne voit pas directement les fichiers de ton Mac. Le plus simple est de pousser ce dossier dans un repository GitHub.

```bash
git init
git add .
git commit -m "Initial Jenkins Vault Helm lab"
git branch -M main
```

Crée ensuite un repository GitHub vide, puis pousse :

```bash
git remote add origin git@github.com:<ton-user>/python-vault-lab.git
git push -u origin main
```

Si le repository est privé, ajoute une credential GitHub dans Jenkins. Pour un premier essai, un repository public simplifie le lab.

## 11. Créer le job Jenkins

Dans Jenkins :

1. `New Item`
2. Nom : `python-vault-lab`
3. Type : `Pipeline`
4. `Definition` : `Pipeline script from SCM`
5. `SCM` : `Git`
6. `Repository URL` : URL GitHub du repository
7. `Branch Specifier` : `*/main`
8. `Script Path` : `Jenkinsfile`
9. Sauvegarde, puis lance `Build Now`

Le build doit :

1. créer un agent Kubernetes avec l'image `jenkins-ci-toolbox:v1`
2. s'authentifier dans Vault avec le service account `jenkins`
3. lire `secret/python-app`
4. déployer le chart Helm dans le namespace `apps`
5. lancer un smoke test HTTP interne au cluster

## 12. Vérifier le résultat

```bash
kubectl -n apps get pods,svc,secrets
kubectl -n apps rollout status deploy/python-app
```

Accès local :

```bash
kubectl -n apps port-forward svc/python-app 8081:8080
```

Dans un autre terminal :

```bash
curl http://localhost:8081
```

Résultat attendu après Jenkins :

```text
DB_USER=admin
DB_PASSWORD_PRESENT=yes
```

## Points à comprendre

- Jenkins ne stocke pas `db_password` dans le chart Git.
- Vault autorise uniquement le service account Kubernetes `jenkins` dans le namespace `jenkins`.
- Le chart crée une `Secret` Kubernetes et l'injecte comme variables d'environnement.
- `kind load docker-image` évite d'utiliser un registry pour ce lab local.
- `imagePullPolicy: IfNotPresent` est nécessaire avec des images chargées localement dans kind.

## Limites volontaires du lab

- Vault `dev` n'est pas persistant et ne doit jamais être utilisé en production.
- Injecter des secrets dans Helm est acceptable pour comprendre le flux, mais en production il faut plutôt étudier Vault Agent Injector, Vault CSI Provider ou External Secrets Operator.
- Le build Docker est fait sur macOS, pas dans Jenkins. Pour aller plus loin, ajoute un registry local, Kaniko ou BuildKit.
- Le mot de passe arrive dans une `Secret` Kubernetes. C'est mieux qu'un secret dans Git, mais ce n'est pas équivalent à une consommation directe depuis Vault par l'application.

## Nettoyage

Supprime tout le lab :

```bash
kind delete cluster --name devops-lab
```

## Références officielles

- kind quick start et chargement d'images : https://kind.sigs.k8s.io/docs/user/quick-start/
- Jenkins Helm chart : https://charts.jenkins.io/
- Jenkins sur Kubernetes : https://www.jenkins.io/doc/book/installing/kubernetes/
- Vault Helm chart : https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm/configuration
- Vault Kubernetes auth method : https://developer.hashicorp.com/vault/docs/auth/kubernetes
