I am a DevOps engineer, I have a Macbook Air M3.

I want to learn about Jenkins interaction with an external secret server to 
store credentials instead of having them exposed in my kubernetes helm charts.


Voici un laboratoire complet que je te recommande. Il te permettra d'apprendre simultanément :

- Jenkins Pipelines
- Helm Charts
- Kubernetes
- Vault
- Python
- Gestion des secrets

Le tout fonctionne très bien sur un Mac avec Docker Desktop.

# Architecture

```text
GitHub
   |
   v
Jenkins
   |
   v
Helm Chart
   |
   v
Kubernetes (kind)
   |
   +--> Python App
   |
   +--> Vault
```

# Étape 1 : Installer les outils

### Docker Desktop

 [oai_citation:0‡docker.com](https://www.docker.com/products/docker-desktop?utm_source=chatgpt.com)

Vérification :

```bash
docker version
```

### Kind

 [oai_citation:1‡kind.sigs.k8s.io](https://kind.sigs.k8s.io?utm_source=chatgpt.com)

```bash
brew install kind
```

### Kubectl

```bash
brew install kubectl
```

### Helm

```bash
brew install helm
```

### Jenkins CLI (facultatif)

```bash
brew install jenkins-lts
```

---

# Étape 2 : Créer un cluster Kubernetes

```bash
kind create cluster --name devops-lab
```

Vérification :

```bash
kubectl get nodes
```

Tu dois voir un nœud `Ready`.

---

# Étape 3 : Installer Jenkins

Ajouter le dépôt Helm :

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update
```

Créer un namespace :

```bash
kubectl create namespace jenkins
```

Installer Jenkins :

```bash
helm install jenkins jenkins/jenkins \
  --namespace jenkins
```

Attendre quelques minutes :

```bash
kubectl get pods -n jenkins
```

---

# Étape 4 : Accéder à Jenkins

```bash
kubectl port-forward svc/jenkins 8080:8080 -n jenkins
```

Puis ouvrir :

```text
http://localhost:8080
```

Récupérer le mot de passe admin :

```bash
kubectl exec --namespace jenkins \
  -it svc/jenkins \
  -- /bin/cat /run/secrets/additional/chart-admin-password
```

---

# Étape 5 : Installer Vault

Ajouter le repo :

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Créer le namespace :

```bash
kubectl create namespace vault
```

Installer Vault en mode dev :

```bash
helm install vault hashicorp/vault \
  --namespace vault \
  --set "server.dev.enabled=true"
```

Vérification :

```bash
kubectl get pods -n vault
```

---

# Étape 6 : Se connecter à Vault

```bash
kubectl port-forward svc/vault 8200:8200 -n vault
```

Ouvrir :

```text
http://localhost:8200
```

Token :

```text
root
```

---

# Étape 7 : Créer un secret

Entrer dans le pod :

```bash
kubectl exec -it \
  -n vault \
  vault-0 -- sh
```

Créer un secret :

```bash
vault kv put secret/db \
  username=admin \
  password=SuperSecret123
```

---

# Étape 8 : Créer une application Python

Structure :

```text
python-app/
├── app.py
├── requirements.txt
├── Dockerfile
└── chart/
```

app.py :

```python
import os

print("Application démarrée")
print("DB_USER =", os.getenv("DB_USER"))
```

---

# Étape 9 : Construire l'image

```bash
docker build -t python-app:v1 .
```

---

# Étape 10 : Créer un Helm Chart

```bash
helm create python-app
```

Tu apprendras alors :

- `values.yaml`
- `deployment.yaml`
- `service.yaml`
- templates Helm
- variables Helm

C'est probablement la compétence Helm la plus demandée en entreprise.

---

# Étape 11 : Jenkins Pipeline

Créer un `Jenkinsfile` :

```groovy
pipeline {
    agent any

    stages {

        stage('Build') {
            steps {
                sh 'docker build -t python-app:v1 .'
            }
        }

        stage('Deploy') {
            steps {
                sh '''
                helm upgrade \
                  --install \
                  python-app \
                  ./chart
                '''
            }
        }
    }
}
```

---

# Étape 12 : Niveau avancé

Une fois ceci maîtrisé :

1. Jenkins récupère un token Vault
2. Vault fournit les secrets
3. Helm injecte les secrets dans Kubernetes
4. L'application Python les utilise

C'est très proche d'une architecture DevOps moderne.

## Ordre d'apprentissage conseillé

1. Kubernetes de base (1 jour)
2. Helm Templates (2-3 jours)
3. Jenkins Pipeline (2 jours)
4. Vault (2 jours)
5. Jenkins ↔ Vault (2 jours)
6. Helm avancé (conditions, loops, helpers)
7. Conjur (optionnel)

Avec ton expérience DevOps, je pense qu'en 2 à 3 semaines de pratique le soir, tu peux construire un labo qui couvre une grande partie des concepts utilisés dans les équipes plateforme et CI/CD actuelles.
