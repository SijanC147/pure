release:
	VERSION=$$(./bump.sh $(TYPE)) && \
		gh release create v$$VERSION --generate-notes

patch:
	$(MAKE) release TYPE=patch

minor:
	$(MAKE) release TYPE=minor

major:
	$(MAKE) release TYPE=major

help:
	@echo "COMMANDS:"
	@echo "  patch          Publish new patch version release."
	@echo "  minor          Publish new minor version release."
	@echo "  major          Publish new major version release."