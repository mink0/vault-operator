# Vault-Secrets Kubernetes Operator

On creation of CRD resource Vault-Secrets Operator will fetch sensitive data from the [HC Vault](https://www.vaultproject.io/)
and will create a [Kubernetes Secret](https://kubernetes.io/docs/concepts/configuration/secret/) object to be used
from k8s applications. On CRD deletion the secret will removed.

## Requirements

- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [HC vault cli](https://www.vaultproject.io/docs/install)

## Start operator in development mode

    make dev
