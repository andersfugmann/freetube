.PHONY: build
build: ## Build the project
build:
	dune build

.PHONY: test
test: ## Run unittests tests
test:
	dune runtest

.PHONY: integration-test
integration-test: ## Run integration tests against local files
integration-test: run
	sleep 1
	./scripts/test_stream.sh static/sample/wildlife/streams.json hevc aac
	./scripts/test_stream.sh static/sample/wildlife/streams.json av1 opus
	./scripts/test_stream.sh static/nyc/streams.json av1 aac
	./scripts/test_stream.sh static/nyc/streams.json vp9 aac

.PHONY: validate-hls
validate-hls: ## Run Apple mediastreamvalidator (no-op if not installed)
validate-hls: run
	sleep 1
	./scripts/validate_hls.sh static/nyc/streams.json hevc aac

.PHONY: run
run: ## Run the server (background, logs to freetube.log)
run: build
	@pkill freetube || true
	nohup dune exec freetube > freetube.log 2>&1 &

.PHONY: stream
stream: ## Stream a YouTube video to a device. Usage: make stream YT=<id|url> [SINK=<device>]
stream:
	@test -n "$(YT)" || (echo "usage: make stream YT=<video_id|streams_url> [SINK=<device>]"; exit 2)
	@dune exec freetube_client -- stream "$(YT)" $(if $(SINK),--sink "$(SINK)")

.PHONY: dep
dep: ## Install dependencies
dep:
	opam install . --deps-only --with-test

.PHONY: plugin
plugin: ## Build the browser plugin (Chrome/Edge MV3) into plugin/dist/
plugin:
	dune build --profile=release src/plugin/
	mkdir -p plugin/dist/icons
	install -m 0644 _build/default/src/plugin/background.bc.js plugin/dist/background.js
	install -m 0644 _build/default/src/plugin/content.bc.js    plugin/dist/content.js
	install -m 0644 _build/default/src/plugin/popup.bc.js      plugin/dist/popup.js
	install -m 0644 plugin/manifest.json plugin/popup.html plugin/dist/
	-find plugin/icons -maxdepth 1 -name '*.png' -exec install -m 0644 {} plugin/dist/icons/ \;
	@echo "Plugin built in plugin/dist/ — load unpacked from there in chrome://extensions"

.PHONY: help
help: ## Show this help
help:
	@grep -h '^\([a-zA-Z_-]\+\):.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
