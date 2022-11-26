export SHELL := $(shell env which bash)

# if PROG is not defined then set it to rexray
ifeq (,$(strip $(PROG)))
PROG := rexray
endif

# this makefile's default target is PROG
all: $(PROG)
build: $(PROG)

# a flag indicating whether or not to use docker for the builds. if
# set to 1 then docker will be used, otherwise go is used
ifeq (,$(strip $(DOCKER)))
DOCKER := $(shell docker version > /dev/null 2>&1 && echo 1)
endif

# store the current directory
PWD := $(shell pwd)

# if GO_VERSION is not defined then parse it from the .travis.yml file
ifeq (,$(strip $(GO_VERSION)))
GO_VERSION := $(shell grep "go:" .travis.yml | head -n 1 | awk '{print $$2}')
endif

# if GO_IMPORT_PATH is not defined then parse it from the .travis.yml file
ifeq (,$(strip $(GO_IMPORT_PATH)))
GO_IMPORT_PATH := $(shell grep "go_import_path:" .travis.yml | head -n 1 | awk '{print $$2}')
endif
# the import path less the github.com/ at the front
GO_IMPORT_PATH_SLUG := $(subst github.com/,,$(GO_IMPORT_PATH))


################################################################################
##                                BUILD                                       ##
################################################################################
ifneq (,$(strip $(DRIVER)))
BUILD_TAGS += $(subst -,,$(DRIVER))
endif

ifneq (,$(strip $(TYPE)))
BUILD_TAGS += $(TYPE)
endif

GOBUILD := build
ifneq (,$(strip $(BUILD_TAGS)))
GOBUILD += -tags '$(BUILD_TAGS)'
endif

# if docker is avaialble then default to using it to build REX-Ray,
# otherwise check to see if go is available. if neither are
# available then print an error
$(PROG):
ifeq (1,$(DOCKER))
	docker run -it \
	  -v "$(PWD)":"/go/src/$(GO_IMPORT_PATH)" golang:$(GO_VERSION) \
	  bash -c "cd \"src/$(GO_IMPORT_PATH)\" && \
	  XGOOS=$(GOOS) XGOARCH=$(GOARCH) GOOS= GOARCH= go generate && \
	  GOOS=$(GOOS) GOARCH=$(GOARCH) go $(GOBUILD) -o \"$(PROG)\""
else
	XGOOS=$(GOOS) XGOARCH=$(GOARCH) GOOS= GOARCH= go generate
	GOOS=$(GOOS) GOARCH=$(GOARCH) go $(GOBUILD) -o "$(PROG)"
endif

clean-build:
	rm -f rexray rexray-client rexray-agent rexray-controller
clean: clean-build

build-all:
	$(MAKE) build
	PROG=$(PROG)-agent BUILD_TAGS=agent $(MAKE) build
	PROG=$(PROG)-client BUILD_TAGS=client $(MAKE) build
	PROG=$(PROG)-controller BUILD_TAGS=controller $(MAKE) build

.PHONY: $(PROG) clean-build build-all


################################################################################
##                                SEMVER                                      ##
################################################################################
# the path to the semver.env file that all non-build targets use in
# order to ensure that they have access to the version-related data
# generated by `go generate`
SEMVER_MK := semver.mk

ifneq (true,$(TRAVIS))
$(SEMVER_MK): .git
endif

$(SEMVER_MK):
ifeq (1,$(DOCKER))
	docker run -it \
	  -v "$(PWD)":"/go/src/$(GO_IMPORT_PATH)" golang:$(GO_VERSION) \
	  bash -c "cd \"src/$(GO_IMPORT_PATH)\" && \
	  XGOOS=$(GOOS) XGOARCH=$(GOARCH) GOOS= GOARCH= go run core/semver/semver.go -f mk -o $@"
else
	XGOOS=$(GOOS) XGOARCH=$(GOARCH) GOOS= GOARCH= go run core/semver/semver.go -f mk -o $@
endif

include $(SEMVER_MK)


################################################################################
##                                TGZ                                         ##
################################################################################
TGZ := $(PROG)-$(OS)-$(ARCH)-$(SEMVER).tar.gz
tgz: $(TGZ)
$(TGZ): $(PROG)
	tar -czf $@ $<
clean-tgz:
	rm -fr $(TGZ)
clean: clean-tgz
.PHONY: clean-tgz


################################################################################
##                                RPM                                         ##
################################################################################
RPMDIR := .rpm
RPM := $(PROG)-$(SEMVER_RPM)-1.$(ARCH).rpm
rpm: $(RPM)
$(RPM): $(PROG)
	rm -fr $(RPMDIR)
	mkdir -p $(RPMDIR)/BUILD \
			 $(RPMDIR)/RPMS \
			 $(RPMDIR)/SRPMS \
			 $(RPMDIR)/SPECS \
			 $(RPMDIR)/SOURCES \
			 $(RPMDIR)/tmp
	cp rpm.spec $(RPMDIR)/SPECS/$(<F).spec
	cd $(RPMDIR) && \
		setarch $(ARCH) rpmbuild -ba \
			-D "rpmbuild $(abspath $(RPMDIR))" \
			-D "v_semver $(SEMVER_RPM)" \
			-D "v_arch $(ARCH)" \
			-D "prog_name $(<F)" \
			-D "prog_path $(abspath $<)" \
			SPECS/$(<F).spec
	mv $(RPMDIR)/RPMS/$(ARCH)/$(RPM) $@
clean-rpm:
	rm -fr $(RPM)
clean: clean-rpm
.PHONY: clean-rpm


################################################################################
##                                DEB                                         ##
################################################################################
DEB := $(PROG)_$(SEMVER_RPM)-1_$(GOARCH).deb
deb: $(DEB)
$(DEB): $(RPM)
	fakeroot alien -k -c --bump=0 $<
clean-deb:
	rm -fr $(DEB)
clean: clean-deb
.PHONY: clean-deb


################################################################################
##                              BINTRAY                                      ##
################################################################################
BINTRAY_FILES := $(foreach r,unstable staged stable,bintray-$r.json)
ifeq (,$(strip $(BINTRAY_SUBJ)))
BINTRAY_SUBJ := rexray
endif

define BINTRAY_GENERATED_JSON
{
   "package": {
        "name":     "$${REPO}",
        "repo":     "rexray",
        "subject":  "$(BINTRAY_SUBJ)"
    },
    "version": {
        "name":     "$(SEMVER)",
        "desc":     "$(SEMVER).Sha.$(SHA32)",
        "released": "$(RELEASE_DATE)",
        "vcs_tag":  "v$(SEMVER)",
        "gpgSign":  false
    },
    "files": [{
        "includePattern": "./($(PROG).*?\.(?:gz|rpm|deb))",
        "excludePattern": "./.*/.*",
        "uploadPattern":  "$${REPO}/$(SEMVER)/$$1"
    }],
    "publish": true
}
endef
export BINTRAY_GENERATED_JSON

bintray: $(BINTRAY_FILES)
$(BINTRAY_FILES): $(SEMVER_MK)
	@echo generating $@
	@echo "$$BINTRAY_GENERATED_JSON" | \
	sed -e 's/$${REPO}/$(@F:bintray-%.json=%)/g' > $@

clean-bintray:
	rm -f $(BINTRAY_FILES)
clean: clean-bintray

.PHONY: clean-bintray


################################################################################
##                                   TEST                                     ##
################################################################################
test:
	$(MAKE) -C libstorage test

.PHONY: test


################################################################################
##                                  COVERAGE                                  ##
################################################################################
COVERAGE_IMPORTS := github.com/onsi/gomega \
  github.com/onsi/ginkgo \
  golang.org/x/tools/cmd/cover

COVERAGE_IMPORTS_PATHS := $(addprefix $(GOPATH)/src/,$(COVERAGE_IMPORTS))

$(COVERAGE_IMPORTS_PATHS):
	go get $(subst $(GOPATH)/src/,,$@)

coverage.out:
	printf "mode: set\n" > coverage.out
	for f in $$(find libstorage -name "*.test.out" -type f); do \
	  grep -v "mode :set" $$f >> coverage.out; \
	done

cover: coverage.out | $(COVERAGE_IMPORTS_PATHS)
	curl -sSL https://codecov.io/bash | bash -s -- -f $<

.PHONY: coverage.out cover


################################################################################
##                                  DOCKER                                    ##
################################################################################
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
SPACE6 := $(SPACE)$(SPACE)$(SPACE)$(SPACE)$(SPACE)$(SPACE)
SPACE8 := $(SPACE6)$(SPACE)$(SPACE)

DOCKER_SEMVER := $(subst +,-,$(SEMVER))
DOCKER_DRIVER := $(DRIVER)

ifeq (undefined,$(origin DOCKER_PLUGIN_ROOT))
DOCKER_PLUGIN_ROOT := $(PROG)
endif
DOCKER_PLUGIN_NAME := $(DOCKER_PLUGIN_ROOT)/$(DOCKER_DRIVER):$(DOCKER_SEMVER)
DOCKER_PLUGIN_NAME_UNSTABLE := $(DOCKER_PLUGIN_ROOT)/$(DOCKER_DRIVER):edge
DOCKER_PLUGIN_NAME_STAGED := $(DOCKER_PLUGIN_NAME)
DOCKER_PLUGIN_NAME_STABLE := $(DOCKER_PLUGIN_ROOT)/$(DOCKER_DRIVER):latest

DOCKER_PLUGIN_BUILD_PATH := .docker/plugins/$(DOCKER_DRIVER)

DOCKER_PLUGIN_DOCKERFILE := $(DOCKER_PLUGIN_BUILD_PATH)/.Dockerfile
ifeq (,$(strip $(wildcard $(DOCKER_PLUGIN_DOCKERFILE))))
DOCKER_PLUGIN_DOCKERFILE := .docker/plugins/Dockerfile
endif
DOCKER_PLUGIN_DOCKERFILE_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/Dockerfile
$(DOCKER_PLUGIN_DOCKERFILE_TGT): $(DOCKER_PLUGIN_DOCKERFILE)
	cp -f $^ $@

DOCKER_PLUGIN_ENTRYPOINT := $(DOCKER_PLUGIN_BUILD_PATH)/.rexray.sh
ifeq (,$(strip $(wildcard $(DOCKER_PLUGIN_ENTRYPOINT))))
DOCKER_PLUGIN_ENTRYPOINT := .docker/plugins/rexray.sh
endif
DOCKER_PLUGIN_ENTRYPOINT_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/$(PROG).sh
$(DOCKER_PLUGIN_ENTRYPOINT_TGT): $(DOCKER_PLUGIN_ENTRYPOINT)
	cp -f $^ $@

DOCKER_PLUGIN_CONFIGFILE := $(DOCKER_PLUGIN_BUILD_PATH)/.rexray.yml
DOCKER_PLUGIN_CONFIGFILE_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/$(PROG).yml
ifeq (,$(strip $(wildcard $(DOCKER_PLUGIN_CONFIGFILE))))
DOCKER_PLUGIN_CONFIGFILE := .docker/plugins/rexray.yml
$(DOCKER_PLUGIN_CONFIGFILE_TGT): $(DOCKER_PLUGIN_CONFIGFILE)
	sed -e 's/$${DRIVER}/$(DRIVER)/g' $^ > $@
else
$(DOCKER_PLUGIN_CONFIGFILE_TGT): $(DOCKER_PLUGIN_CONFIGFILE)
	cp -f $^ $@
endif

DOCKER_PLUGIN_REXRAYFILE := $(PROG)
DOCKER_PLUGIN_REXRAYFILE_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/$(PROG)
$(DOCKER_PLUGIN_REXRAYFILE_TGT): $(DOCKER_PLUGIN_REXRAYFILE)
	cp -f $^ $@

DOCKER_PLUGIN_CONFIGJSON_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/config.json

DOCKER_PLUGIN_ENTRYPOINT_ROOTFS_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/rootfs/$(PROG).sh
docker-build-plugin: build-docker-plugin
build-docker-plugin: $(DOCKER_PLUGIN_ENTRYPOINT_ROOTFS_TGT)
$(DOCKER_PLUGIN_ENTRYPOINT_ROOTFS_TGT): $(DOCKER_PLUGIN_CONFIGJSON_TGT) \
										$(DOCKER_PLUGIN_DOCKERFILE_TGT) \
										$(DOCKER_PLUGIN_ENTRYPOINT_TGT) \
										$(DOCKER_PLUGIN_CONFIGFILE_TGT) \
										$(DOCKER_PLUGIN_REXRAYFILE_TGT)
	docker plugin rm $(DOCKER_PLUGIN_NAME) 2> /dev/null || true
	sudo rm -fr $(@D)
	docker build \
	  --label `driver="$(DRIVER)"` \
	  --label `semver="$(SEMVER)"` \
	  -t rootfsimage $(<D) && \
	  id=$$(docker create rootfsimage true) && \
	  sudo mkdir -p $(@D) && \
	  sudo docker export "$$id" | sudo tar -x -C $(@D) && \
	  docker rm -vf "$$id" && \
	  docker rmi rootfsimage
	sudo docker plugin create $(DOCKER_PLUGIN_NAME) $(<D)
	docker plugin ls

push-docker-plugin:
ifeq (1,$(DOCKER_PLUGIN_$(DOCKER_DRIVER)_NOPUSH))
	echo "docker plugin push disabled"
else
	@docker login -u $(DOCKER_USER) -p $(DOCKER_PASS)
ifeq (unstable,$(DOCKER_PLUGIN_TYPE))
	sudo docker plugin create $(DOCKER_PLUGIN_NAME_UNSTABLE) $(DOCKER_PLUGIN_BUILD_PATH)
	docker plugin push $(DOCKER_PLUGIN_NAME_UNSTABLE)
endif
ifeq (staged,$(DOCKER_PLUGIN_TYPE))
	docker plugin push $(DOCKER_PLUGIN_NAME_STAGED)
endif
ifeq (stable,$(DOCKER_PLUGIN_TYPE))
	docker plugin push $(DOCKER_PLUGIN_NAME)
	sudo docker plugin create $(DOCKER_PLUGIN_NAME_UNSTABLE) $(DOCKER_PLUGIN_BUILD_PATH)
	docker plugin push $(DOCKER_PLUGIN_NAME_UNSTABLE)
	sudo docker plugin create $(DOCKER_PLUGIN_NAME_STABLE) $(DOCKER_PLUGIN_BUILD_PATH)
	docker plugin push $(DOCKER_PLUGIN_NAME_STABLE)
endif
ifeq (,$(DOCKER_PLUGIN_TYPE))
	docker plugin push $(DOCKER_PLUGIN_NAME)
endif
endif

.PHONY: docker-build-plugin build-docker-plugin push-docker-plugin


################################################################################
##                                   DEP                                      ##
################################################################################
DEP := ./dep
DEP_VER ?= 0.3.0
DEP_ZIP := dep-$$GOHOSTOS-$$GOHOSTARCH.zip
DEP_URL := https://github.com/golang/dep/releases/download/v$(DEP_VER)/$$DEP_ZIP

$(DEP):
	GOVERSION=$$(go version | awk '{print $$4}') && \
	GOHOSTOS=$$(echo $$GOVERSION | awk -F/ '{print $$1}') && \
	GOHOSTARCH=$$(echo $$GOVERSION | awk -F/ '{print $$2}') && \
	DEP_ZIP="$(DEP_ZIP)" && \
	DEP_URL="$(DEP_URL)" && \
	mkdir -p .dep && \
	cd .dep && \
	curl -sSLO $$DEP_URL && \
	unzip "$$DEP_ZIP" && \
	mv $(@F) ../ && \
	cd ../ && \
	rm -fr .dep
ifneq (./dep,$(DEP))
dep: $(DEP)
endif

dep-update: | $(DEP)
	$(DEP) ensure -v

dep-install: | $(DEP)
	$(DEP) ensure -v -vendor-only

.PHONY: dep-update dep-install

################################################################################
##                                   GIST                                     ##
################################################################################
TRAVIS_BUILD_URL := https://travis-ci.org/$(TRAVIS_REPO_SLUG)/builds/$(TRAVIS_BUILD_ID)
TRAVIS_JOB_URL := https://travis-ci.org/$(TRAVIS_REPO_SLUG)/jobs/$(TRAVIS_JOB_ID)
GIST_FILES := $(BINTRAY_FILES) semver.env
ifneq (,$(strip $(DRIVER)))
GIST_DRIVER := .docker/plugins/$(DRIVER)
ifneq (,$(wildcard $(GIST_DRIVER)))
GIST_FILES += $(shell find "$(GIST_DRIVER)" -maxdepth 1 -type f \
	-not -name "rexray" \
	-not -name ".gitignore" \
	-not -name "README.md")
endif
endif

UNAME_TXT := uname.txt
$(UNAME_TXT):
	uname -a > $@
GIST_FILES += $(UNAME_TXT)

FILES_TXT := files.txt
$(FILES_TXT):
	ls -al > $@
.PHONY: $(FILES_TXT)
GIST_FILES += $(FILES_TXT)

MD5SUM_TXT := md5sum.txt
$(MD5SUM_TXT): $(PROG)
	md5sum $< > $@
GIST_FILES += $(MD5SUM_TXT)

DOCKER_OUT_DIR := /tmp/rexray
DOCKER_GIT_DIR := /go/src/$(GO_IMPORT_PATH)

ifneq (,$(strip $(DRIVER)))
define GIST_README_CONTENT_DRIVER

| **Driver** | `$(DRIVER)` |
endef
endif

# built from GO_IMPORT_PATH_SLUG
ifeq ($(GO_IMPORT_PATH_SLUG),$(TRAVIS_REPO_SLUG))
# built from GO_IMPORT_PATH_SLUG AND pull request
ifneq (false,$(TRAVIS_PULL_REQUEST))
define GIST_GIT_FETCH

    git fetch origin +refs/pull/$(TRAVIS_PULL_REQUEST)/merge: &&
    git fetch --tags origin &&
endef
else
# built from GO_IMPORT_PATH_SLUG and NOT pull request
define GIST_GIT_FETCH

    git fetch --tags origin &&
endef
endif
# built from NOT GO_IMPORT_PATH_SLUG
else
# built from NOT GO_IMPORT_PATH_SLUG AND pull request
ifneq (false,$(TRAVIS_PULL_REQUEST))
define GIST_GIT_FETCH

    git fetch origin +refs/pull/$(TRAVIS_PULL_REQUEST)/merge: &&
    git remote add upstream https://$(GO_IMPORT_PATH) &&
    git fetch --tags upstream &&
endef
else
# built from NOT GO_IMPORT_PATH_SLUG AND NOT pull request
define GIST_GIT_FETCH

    git remote add upstream https://$(GO_IMPORT_PATH) &&
    git fetch --tags upstream &&
endef
endif
endif

define GIST_README_CONTENT
# REX-Ray Build [$(TRAVIS_JOB_ID)]($(TRAVIS_JOB_URL))
This gist contains information about REX-Ray build
[$(TRAVIS_BUILD_ID)]($(TRAVIS_BUILD_URL)), job
[$(TRAVIS_JOB_ID)]($(TRAVIS_JOB_URL)).

| Key | Value |
|-----|-------|
| **Binary** | `$(PROG)` |
| **MD5Sum** | `$${MD5SUM}` |
| **SemVer** | `$(SEMVER)` |$(GIST_README_CONTENT_DRIVER)

A REX-Ray binary with a matching checksum can be created
locally using Docker:

```
$$ docker run -it \\
  -v "$$(pwd)":"$(DOCKER_OUT_DIR)" \\
  golang:$(GO_VERSION) \\
  bash -c "git clone https://github.com/$(TRAVIS_REPO_SLUG) \\
      \"$(DOCKER_GIT_DIR)\" &&
    cd \"$(DOCKER_GIT_DIR)\" && $(GIST_GIT_FETCH)
    git checkout -b $(SHA7) $(SHA32) &&
    XGOOS=$(GOOS) XGOARCH=$(GOARCH) GOOS= GOARCH= go generate &&
    GOOS=$(GOOS) GOARCH=$(GOARCH) go $(GOBUILD) -o \"$(PROG)\" &&
    cp -f \"$(PROG)\" \"$(DOCKER_OUT_DIR)\"" && \\
  md5sum "$(PROG)" && \\
  ls -al "$(PROG)"
```
endef
export GIST_README_CONTENT

GIST_README := .gist/README.md
$(GIST_README): $(MD5SUM_TXT)
	@echo generating $@ && mkdir -p $(@D)
	@echo "$$GIST_README_CONTENT" | sed \
	  -e 's/$${MD5SUM}/'"$$(cat $< | awk '{print $$1}')"'/g' \
	  -e 's/\\\\/\\/g' \
	  > $@
.PHONY: $(GIST_README)
GIST_FILES += $(GIST_README)

create-gist: $(GIST_FILES)
	@echo create gist
	-gist -d "$(TRAVIS_JOB_URL)" $^
.PHONY: create-gist


################################################################################
##                                   CLEAN                                    ##
################################################################################
clean:

.PHONY: all clean
