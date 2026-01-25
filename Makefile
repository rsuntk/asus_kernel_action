format:
	find . -type f -name "*.sh" -print0 | xargs -0 shfmt -i 4 -w
