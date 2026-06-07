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

