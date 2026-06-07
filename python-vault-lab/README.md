# Python Vault Lab

This project contains the runnable files for the Jenkins + Vault + Helm lab.

## Structure

```text
python-vault-lab/
├── Jenkinsfile
├── app/
│   ├── Dockerfile
│   ├── app.py
│   └── requirements.txt
├── chart/
│   └── python-app/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── secret.yaml
│           └── service.yaml
├── ci/
│   └── Dockerfile
└── k8s/
    ├── jenkins-deployer-rbac.yaml
    └── vault-tokenreview-rbac.yaml
```

Build and load the application image:

```bash
docker build -t python-vault-lab:v1 ./app
kind load docker-image python-vault-lab:v1 --name devops-lab
```

Build and load the Jenkins agent image:

```bash
docker build -t jenkins-ci-toolbox:v1 ./ci
kind load docker-image jenkins-ci-toolbox:v1 --name devops-lab
```

Validate the Helm chart:

```bash
helm lint ./chart/python-app \
  --set-string secrets.dbUser=test \
  --set-string secrets.dbPassword=test

helm template python-app ./chart/python-app \
  --set-string secrets.dbUser=test \
  --set-string secrets.dbPassword=test
```

