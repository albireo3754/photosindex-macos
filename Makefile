.PHONY: app install install-cli test test-signing test-workflow clean

app:
	./scripts/build-app.sh

install: app
	./scripts/install-cli.sh

install-cli: install

test:
	./scripts/test-sign-app.zsh
	node --test workflows/photosindex-development.test.mjs
	swift test

test-signing:
	./scripts/test-sign-app.zsh

test-workflow:
	node --test workflows/photosindex-development.test.mjs

clean:
	swift package clean
