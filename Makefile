.PHONY: release prepare-release publish patch minor major test-release-safety help

# Legacy aliases now prepare a PR; they never publish a release.
release: prepare-release

prepare-release:
	./bump.sh "$(TYPE)"

patch:
	$(MAKE) prepare-release TYPE=patch

minor:
	$(MAKE) prepare-release TYPE=minor

major:
	$(MAKE) prepare-release TYPE=major

publish:
	./bump.sh publish "$(VERSION)" "$(COMMIT)"

test-release-safety:
	bash tests/release-safety.sh

help:
	@echo "  patch/minor/major   Prepare a release branch and pull request."
	@echo "  release TYPE=patch Alias for release preparation (does not publish)."
	@echo "  publish VERSION=X COMMIT=<full SHA> Publish validated current main."
	@echo "  test-release-safety Run isolated release helper tests."
