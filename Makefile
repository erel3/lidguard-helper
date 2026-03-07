.PHONY: build clean

build:
	swift build -c release

clean:
	rm -rf .build
