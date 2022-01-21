
# Image URL to use all building/pushing image targets
IMG ?= controller:latest
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.23

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" go test ./... -coverprofile cover.out

##@ Build

.PHONY: build
build: generate fmt vet ## Build manager binary.
	go build -o bin/manager main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

.PHONY: docker-build
docker-build: test ## Build docker image with the manager.
	docker build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMG}

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
.PHONY: controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.8.0)

KUSTOMIZE = $(shell pwd)/bin/kustomize
.PHONY: kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

ENVTEST = $(shell pwd)/bin/setup-envtest
.PHONY: envtest
envtest: ## Download envtest-setup locally if necessary.
	$(call go-get-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest@latest)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

#
# User customizations
#

env_file := $(PROJECT_DIR)/.env
ifneq ("$(wildcard $(env_file))","")
	include $(env_file)
	export
endif

TOKEN_PATH := ${PROJECT_DIR}/config/samples/sa_token
init:
	$(eval export VAULT_JWT_FILE=${TOKEN_PATH}/token)
	$(eval export K8S_SA_CRT=${TOKEN_PATH}/ca.crt)
	$(eval export VAULT_ADDR=http://0.0.0.0:8200)
	$(eval export K8S_API_URL=$(shell kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'))

.PHONY: config
config: init
	@echo export VAULT_ADDR=${VAULT_ADDR}
	@echo export VAULT_JWT_FILE=${VAULT_JWT_FILE}

k8s-create:	# https://github.com/kubernetes-sigs/kind/releases
	-kind create cluster --name operator --image kindest/node:v1.20.7
	kubectl cluster-info --context kind-operator

k8s-delete:
	kind delete cluster --name operator

k8s-get-sa-token:
	$(eval export SA_SEC_NAME=$(shell kubectl get sa default -o jsonpath="{.secrets[*].name}"))
	$(eval export SA_JWT_TOKEN=$(shell kubectl get secret ${SA_SEC_NAME} -o jsonpath="{.data.token}"))
	$(eval export SA_CA_CRT=$(shell kubectl get secret ${SA_SEC_NAME} -o jsonpath="{.data['ca\.crt']}"))

	@echo "${SA_JWT_TOKEN}" | base64 --decode > ${TOKEN_PATH}/token
	@echo "${SA_CA_CRT}" | base64 --decode > ${TOKEN_PATH}/ca.crt

k8s: k8s-create install samples

samples:
	kubectl replace --force -f config/samples

vault-server:
	vault server -tls-skip-verify -dev -dev-root-token-id root -dev-listen-address 0.0.0.0:8200 &

vault-login: init
	vault login token=root

vault-init: init k8s-get-sa-token vault-login
	-vault auth enable kubernetes

	vault policy write vault-op \
		${PROJECT_DIR}/config/samples/vault_policy/default.hcl

	vault write auth/kubernetes/config \
		token_reviewer_jwt=@${VAULT_JWT_FILE} \
		kubernetes_host=${K8S_API_URL} \
		kubernetes_ca_cert=@${K8S_SA_CRT}

	vault write auth/kubernetes/role/vault-op \
		bound_service_account_names='*' \
		bound_service_account_namespaces='*' \
		policies=vault-op \
		ttl=12h

	vault write auth/kubernetes/login \
		role=vault-op \
		jwt=@${VAULT_JWT_FILE}

	vault kv put secret/test username='john doe' password='pa$$w0rd'

vault: vault-server vault-login vault-init

dev: k8s vault
	air -c .air.toml
