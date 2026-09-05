XCODEGEN ?= xcodegen
XCODEBUILD ?= xcodebuild
PROJECT := Watchamacallit.xcodeproj
SCHEME := Watchamacallit
DESTINATION ?= generic/platform=watchOS
CODE_SIGNING_ALLOWED ?= NO

.PHONY: help check-xcodegen generate build open clean

help:
	@echo "make generate  Generate the Xcode project"
	@echo "make build     Generate and build for watchOS"
	@echo "make open      Generate and open the project"
	@echo "make clean     Clean Xcode build products"

check-xcodegen:
	@command -v $(XCODEGEN) >/dev/null 2>&1 || { \
		echo "XcodeGen is required. Install it with: brew install xcodegen"; \
		exit 1; \
	}

generate: check-xcodegen
	@test -f Watchamacallit/AppSecrets.swift || cp Watchamacallit/AppSecrets.swift.template Watchamacallit/AppSecrets.swift
	$(XCODEGEN) generate --spec project.yml

build: generate
	$(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		CODE_SIGNING_ALLOWED=$(CODE_SIGNING_ALLOWED) \
		build

open: generate
	open $(PROJECT)

clean:
	$(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		clean
