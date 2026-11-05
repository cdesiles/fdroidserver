.DEFAULT_GOAL := help
.PHONY: help image check lock clean

# fdroidserver's version, as pinned in requirements.txt. CI publishes
# ghcr.io/cdesiles/fdroidserver:<version>-<build>, :<version> and :latest.
FDROID_VERSION := $(shell sed -n 's/^fdroidserver==//p' requirements.txt)
IMAGE ?= fdroidserver:$(FDROID_VERSION)
# Empty: this machine's platform. linux/amd64 builds for an x86_64 server from
# an arm64 laptop, emulated, so slower.
PLATFORM ?=
CONTAINER ?= docker
# The image's base, so that `lock` resolves the pins for the image's own Python
BASE := $(shell sed -n 's/^FROM \(.*\) AS build$$/\1/p' Dockerfile)

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "; print "\nUsage:\n  make \033[36m<target>\033[0m"} \
		/^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-6s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo

image: ## Build fdroidserver:<version> (PLATFORM=linux/amd64 for another platform, CONTAINER=podman)
	$(CONTAINER) build $(if $(PLATFORM),--platform $(PLATFORM)) --tag $(IMAGE) .

check: image ## Build, then run the image on a throwaway repository: key, index, signatures, HTTP
	CONTAINER=$(CONTAINER) PLATFORM=$(PLATFORM) sh check.sh $(IMAGE)

lock: ## Pin the latest fdroidserver and its dependencies in requirements.txt (FDROID=x.y.z for another release)
	$(CONTAINER) run --rm $(BASE) sh -c ' \
		export DEBIAN_FRONTEND=noninteractive; \
		apt-get update -qq && apt-get install -qqy --no-install-recommends python3-venv >/dev/null \
		&& python3 -m venv /v && /v/bin/pip install -q "fdroidserver$(if $(FDROID),==$(FDROID))" \
		&& /v/bin/pip freeze' > requirements.txt.new
	mv requirements.txt.new requirements.txt

clean: ## Remove the downloaded test APK
	rm -rf .cache
