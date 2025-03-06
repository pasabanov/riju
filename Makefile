SHELL := bash
.SHELLFLAGS := -o pipefail -euc

export PATH := $(PWD)/bin:$(PWD)/cli/out:$(PWD)/system/out:$(PATH)

-include .env
export

BUILD := build/$(T)/$(L)
DEB := riju-$(T)-$(L).deb
S3 := s3://$(S3_BUCKET)
S3_CONFIG_PATH ?= config.json
S3_DEB := $(S3)/debs/$(DEB)
S3_CONFIG := $(S3)/$(S3_CONFIG_PATH)

ifneq ($(CMD),)
C_CMD := -c '$(CMD)'
BASH_CMD := bash -c '$(CMD)'
else
C_CMD :=
BASH_CMD :=
endif

# Get rid of 'Entering directory' / 'Leaving directory' messages.
MAKE_QUIETLY := MAKELEVEL= make

REQUIRE_PACKAGING := @if [[ $${HOSTNAME} != packaging ]]; then echo >&2 "packages should be built in packaging container"; exit 1; fi

.PHONY: all $(MAKECMDGOALS) frontend system supervisor

 all: help

### Docker management

ifneq ($(NC),)
NO_CACHE := --no-cache
else
NO_CACHE :=
endif

ifeq ($(NI),)
IT_ARG := -it
else
IT_ARG :=
endif

## Pass NC=1 to disable the Docker cache.

image: # I=<image> [L=<lang>] [NC=1] : Build a Docker image
	@: $${I}
ifeq ($(I),lang)
	@: $${L}
	node tools/build-lang-image.js --lang $(L)
else ifneq (,$(filter $(I),admin ci))
	docker build . -f docker/$(I)/Dockerfile -t riju:$(I) $(NO_CACHE)
else
	docker build . -f docker/$(I)/Dockerfile -t riju:$(I) $(NO_CACHE)
endif

VOLUME_MOUNT ?= $(PWD)

# http
P1 ?= 6119
# https
P2 ?= 6120
# metrics
P3 ?= 6121

ifneq (,$(EE))
SHELL_PORTS := -p 0.0.0.0:$(P1):6119 -p 0.0.0.0:$(P2):6120 -p 0.0.0.0:$(P3):6121
else ifneq (,$(E))
SHELL_PORTS := -p 127.0.0.1:$(P1):6119 -p 127.0.0.1:$(P2):6120 -p 127.0.0.1:$(P3):6121
else
SHELL_PORTS :=
endif

SHELL_ENV := -e Z -e CI -e TEST_PATIENCE -e TEST_CONCURRENCY -e TEST_TIMEOUT_SECS

ifeq ($(I),lang)
LANG_TAG := lang-$(L)
else
LANG_TAG := $(I)
endif

shell: # I=<shell> [L=<lang>] [E[E]=1] [P1|P2=<port>] [CMD="<arg>..."] : Launch Docker image with shell
	@: $${I}
ifneq (,$(filter $(I),admin ci))
	@mkdir -p $(HOME)/.aws $(HOME)/.docker $(HOME)/.ssh $(HOME)/.terraform.d
	docker run $(IT_ARG) --rm --hostname $(I) -v $(VOLUME_MOUNT):/src -v /var/cache/riju:/var/cache/riju -v /var/run/docker.sock:/var/run/docker.sock -v $(HOME)/.aws:/var/cache/riju/.aws -v $(HOME)/.docker:/var/cache/riju/.docker -v $(HOME)/.ssh:/var/cache/riju/.ssh -v $(HOME)/.terraform.d:/var/cache/riju/.terraform.d -e NI -e AWS_REGION -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e DOCKER_REPO -e PUBLIC_DOCKER_REPO -e S3_BUCKET -e DOMAIN -e VOLUME_MOUNT=$(VOLUME_MOUNT) $(SHELL_PORTS) $(SHELL_ENV) --network host riju:$(I) $(BASH_CMD)
else ifeq ($(I),app)
	docker run $(IT_ARG) --rm --hostname $(I) -v /var/cache/riju:/var/cache/riju -v /var/run/docker.sock:/var/run/docker.sock $(SHELL_PORTS) $(SHELL_ENV) riju:$(I) $(BASH_CMD)
else ifneq (,$(filter $(I),base lang))
ifeq ($(I),lang)
	@: $${L}
endif
	docker run $(IT_ARG) --rm --hostname $(LANG_TAG) -v $(VOLUME_MOUNT):/src $(SHELL_PORTS) $(SHELL_ENV) riju:$(LANG_TAG) $(BASH_CMD)
else ifeq ($(I),runtime)
	docker run $(IT_ARG) --rm --hostname $(I) -v $(VOLUME_MOUNT):/src -v /var/cache/riju:/var/cache/riju -v /var/run/docker.sock:/var/run/docker.sock $(SHELL_PORTS) $(SHELL_ENV) riju:$(I) $(BASH_CMD)
else
	docker run $(IT_ARG) --rm --hostname $(I) -v $(VOLUME_MOUNT):/src $(SHELL_PORTS) $(SHELL_ENV) riju:$(I) $(BASH_CMD)
endif

ecr: # Authenticate to ECR (temporary credentials)
	aws ecr get-login-password | docker login --username AWS --password-stdin $(subst /riju,,$(DOCKER_REPO))
	aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin $(subst /riju,,$(PUBLIC_DOCKER_REPO))

### Build packaging scripts

script: # L=<lang> T=<type> : Generate a packaging script
	@: $${L} $${T}
	node tools/generate-build-script.js --lang $(L) --type $(T)

all-scripts: # Generate packaging scripts for all languages
	node tools/write-all-build-scripts.js

### Run packaging scripts

pkg-clean: # L=<lang> T=<type> : Set up fresh packaging environment
	@: $${L} $${T}
	$(REQUIRE_PACKAGING)
	sudo rm -rf $(BUILD)/src $(BUILD)/pkg
	mkdir -p $(BUILD)/src $(BUILD)/pkg

pkg-build: # L=<lang> T=<type> : Run packaging script in packaging environment
	@: $${L} $${T}
	$(REQUIRE_PACKAGING)
	cd $(BUILD)/src && pkg="$(PWD)/$(BUILD)/pkg" src="$(PWD)/$(BUILD)/src" $(or $(BASH_CMD),../build.bash)

pkg-debug: # L=<lang> T=<type> : Launch shell in packaging environment
	@: $${L} $${T}
	$(REQUIRE_PACKAGING)
	$(MAKE_QUIETLY) pkg-build L=$(L) T=$(T) CMD=bash

Z ?= none

## Z is the compression type to use; defaults to none. Higher
## compression levels (gzip is moderate, xz is high) take much longer
## but produce much smaller packages.

pkg-deb: # L=<lang> T=<type> [Z=gzip|xz] : Build .deb from packaging environment
	@: $${L} $${T}
	$(REQUIRE_PACKAGING)
	fakeroot dpkg-deb --build -Z$(Z) $(BUILD)/pkg $(BUILD)/$(DEB)

## This is equivalent to the sequence 'pkg-clean', 'pkg-build', 'pkg-deb'.

pkg: pkg-clean pkg-build pkg-deb # L=<lang> T=<type> [Z=gzip|xz] : Build fresh .deb

### Build and run application code

frontend: # Compile frontend assets for production
	npx webpack --mode=production

frontend-dev: # Compile and watch frontend assets for development
	watchexec -w webpack.config.cjs -w node_modules -r --no-environment -- "echo 'Running webpack...' >&2; npx webpack --mode=development --watch"

system: # Compile setuid binary for production
	./system/compile.bash

system-dev: # Compile and watch setuid binary for development
	watchexec -w system/res -w system/src -n -- ./system/compile.bash

supervisor: # Compile supervisor binary for production
	./supervisor/compile.bash

supervisor-dev: # Compile and watch supervisor binary for development
	watchexec -w supervisor/src -n -- ./supervisor/compile.bash

cli: # Compile cli binary for production
	./cli/compile.bash

cli-dev: # Compile and watch cli binary for development
	watchexec -w cli/src -n -- ./cli/compile.bash

server: # Run server for production
	node backend/server.js

server-dev: # Run and restart server for development
	watchexec -w backend -r -n -- node backend/server.js

build: frontend system supervisor # Compile all artifacts for production

dev: # Compile, run, and watch all artifacts and server for development
	$(MAKE_QUIETLY) -j4 frontend-dev system-dev supervisor-dev server-dev

### Application tools

## L is a language identifier or a comma-separated list of them, to
## filter tests by language. T is a test type (run, repl, lsp, format,
## etc.) or a set of them to filter tests that way. If both filters
## are provided, then only tests matching both are run.

test: # [L=<lang>[,...]] [T=<test>[,...]] : Run test(s) for language or test category
	node backend/test-runner.js

## Functions such as 'repl', 'run', 'format', etc. are available in
## the sandbox, and initial setup has already been done (e.g. 'setup'
## command, template code written to main).

sandbox: # L=<lang> : Run isolated shell with per-language setup
	@: $${L}
	L=$(L) node backend/sandbox.js

## L can be either a language ID or a (quoted) custom command to start
## the LSP. This does not run in a sandbox; the server is started
## directly in the current working directory.

lsp: # L=<lang|cmd> : Run LSP REPL for language or custom command line
	@: $${L}
	node backend/lsp-repl.js $(L)

### Fetch artifacts from registries

PUBLIC_DOCKER_REPO_PULL ?= public.ecr.aws/radian-software/riju

sync-ubuntu: # Pull Riju Ubuntu image from public Docker registry
	docker pull $(PUBLIC_DOCKER_REPO_PULL):ubuntu
	docker tag $(PUBLIC_DOCKER_REPO_PULL):ubuntu riju:ubuntu

pull: # I=<image> : Pull last published Riju image from Docker registry
	@: $${I} $${DOCKER_REPO}
	docker pull $(DOCKER_REPO):$(I)
	docker tag $(DOCKER_REPO):$(I) riju:$(I)

download: # L=<lang> T=<type> : Download last published .deb from S3
	@: $${L} $${T} $${S3_BUCKET}
	mkdir -p $(BUILD)
	aws s3 cp $(S3_DEB) $(BUILD)/$(DEB)

undeploy: # Pull latest deployment config from S3
	mkdir -p build
	aws s3 cp $(S3_CONFIG) build/config.json

### Publish artifacts to registries

push: # I=<image> : Push Riju image to Docker registry
	@: $${I} $${DOCKER_REPO}
	docker tag riju:$(I) $(DOCKER_REPO):$(I)
	docker push $(DOCKER_REPO):$(I)

upload: # L=<lang> T=<type> : Upload .deb to S3
	@: $${L} $${T} $${S3_BUCKET}
	tools/ensure-deb-compressed.bash
	aws s3 cp $(BUILD)/$(DEB) $(S3_DEB)

deploy-config: # Generate deployment config file
	node tools/generate-deploy-config.js

deploy-latest: # Upload deployment config to S3 and update ASG instances
	aws s3 cp build/config.json $(S3_CONFIG)

deploy: deploy-config deploy-latest # Shorthand for deploy-config followed by deploy-latest

### Code formatting

fmt-c: # Format C code
	git ls-files | grep -E '\.c$$' | xargs clang-format -i

fmt-go: # Format Go code
	git ls-files | grep -E '\.go$' | xargs gofmt -l -w

fmt-python: # Format Python code
	git ls-files | grep -E '\.py$$' | xargs black -q

fmt-terraform: # Format Terraform code
	terraform fmt "$(PWD)/tf"

fmt-web: # Format CSS, JSON, and YAML code
	git ls-files | grep -E '\.(|css|c?js|json|ya?ml)$$' | grep -Ev '^(langs|shared)/' | xargs prettier --write --loglevel=warn

fmt: fmt-c fmt-go fmt-python fmt-terraform fmt-web # Format all code

### Infrastructure

packer: supervisor # Build and publish a new webserver AMI
	tools/packer-build.bash

deploy-alerts: # Deploy alerting configuration to Grafana Cloud
	envsubst < grafana/alertmanager.yaml > grafana/alertmanager.yaml.out
	cortextool rules load grafana/alerts.yaml --address=https://$(GRAFANA_PROMETHEUS_HOSTNAME) --id=$(GRAFANA_PROMETHEUS_USERNAME) --key=$(GRAFANA_API_KEY)
	cortextool alertmanager load grafana/alertmanager.yaml.out --address=https://alertmanager-us-central1.grafana.net --id=$(GRAFANA_ALERTMANAGER_USERNAME) --key=$(GRAFANA_API_KEY)

### Miscellaneous

## Run this every time you update .gitignore or .dockerignore.in.

dockerignore: # Update .dockerignore from .gitignore and .dockerignore.in
	echo "# This file is generated by 'make dockerignore', do not edit." > .dockerignore
	cat .gitignore | sed 's/#.*//' | grep . | sed 's#^#**/#' >> .dockerignore

## You need to be inside a 'make env' shell whenever you are running
## manual commands (Docker, Terraform, Packer, etc.) directly, as
## opposed to through the Makefile.

env: # [CMD=<target>] : Run shell with .env file loaded and $PATH fixed
	exec bash $(C_CMD)

tmux: # Start or attach to tmux session
	MAKELEVEL= tmux attach || MAKELEVEL= tmux new-session -s tmux

 usage:
	@cat Makefile | \
		grep -E '^[^.:[:space:]]+:|[#]##' | \
		sed -E 's/:[^#]*#([^:]+)$$/: #:\1/' | \
		sed -E 's/([^.:[:space:]]+):([^#]*#(.+))?.*/  make \1\3/' | \
		sed -E 's/[#][#]# *(.+)/\n    (\1)\n/' | \
		sed 's/$$/:/' | \
		column -ts:

help: # [CMD=<target>] : Show available targets, or detailed help for target
ifeq ($(CMD),)
	@echo "usage:"
	@make -s usage
	@echo
else
	@if ! make -s usage | grep -q "make $(CMD) "; then echo "no such target: $(CMD)"; exit 1; fi
	@echo "usage:"
	@make -s usage | grep "make $(CMD)"
	@echo
	@cat Makefile | \
		grep -E '^[^.:[:space:]]+:|^##[^#]' | \
		sed '/$(CMD):/Q' | \
		tac | \
		sed '/^[^#]/Q' | \
		tac | \
		sed -E 's/[# ]+//'
endif
