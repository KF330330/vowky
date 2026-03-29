.PHONY: build deploy deploy-skip-notarize bump-patch bump-minor bump-major preflight verify help dev run

help: ## 显示帮助信息
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## 构建 DMG（Developer ID 签名 + 公证）
	./deploy/build.sh

deploy: ## 构建并部署到 vowky.com
	./deploy/deploy.sh

deploy-skip-notarize: ## 部署（跳过公证，Apple timestamp 不可用时使用）
	SKIP_NOTARIZE=1 ./deploy/deploy.sh

bump-patch: ## 版本号 patch +1（如 1.0.0 → 1.0.1）
	./deploy/bump-version.sh patch

bump-minor: ## 版本号 minor +1（如 1.0.0 → 1.1.0）
	./deploy/bump-version.sh minor

bump-major: ## 版本号 major +1（如 1.0.0 → 2.0.0）
	./deploy/bump-version.sh major

preflight: ## 部署前环境预检
	./deploy/preflight.sh

verify: ## 验证部署结果
	./deploy/verify.sh

dev: ## 开发构建（Debug，带签名）
	cd VowKy && xcodegen generate && \
	xcodebuild build \
		-project VowKy.xcodeproj \
		-scheme VowKy \
		-configuration Debug \
		| tail -3

run: dev ## 构建并启动 App
	@pkill -x VowKy 2>/dev/null || true
	@sleep 0.5
	@open "$$(find ~/Library/Developer/Xcode/DerivedData -name 'VowKy.app' -path '*/Debug/*' -maxdepth 5 2>/dev/null | head -1)"
