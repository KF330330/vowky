.PHONY: build deploy deploy-resume deploy-skip-notarize bump-patch bump-minor bump-major preflight verify help dev run

help: ## 显示帮助信息
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## 构建 DMG（Developer ID 签名 + 公证）
	./deploy/build.sh

deploy: ## 构建并部署到 vowky.com
	./deploy/deploy.sh

deploy-resume: ## 复用已构建+已公证的 DMG，只重试上传（部署上传半路失败后用）
	RESUME=1 ./deploy/deploy.sh

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

# 开发构建工具链：Xcode-26.app 存在则钉住（SpeechAnalyzer 需 macOS 26 SDK），
# 缺失则警告后回落系统默认（其他机器仍可构建，但不含需求 C 功能）。
# 本机布局（2026-08）：App Store 升级 /Applications/Xcode.app 到 26.x，
# Xcode-26.app 是指向它的软链；16.2 回退备份在 /Applications/Xcode-16.2.app。
# 回退验证：VOWKY_DEVELOPER_DIR=/Applications/Xcode-16.2.app/Contents/Developer make dev
VOWKY_XCODE26 := /Applications/Xcode-26.app/Contents/Developer
ifdef VOWKY_DEVELOPER_DIR
  DEV_TOOLCHAIN := DEVELOPER_DIR=$(VOWKY_DEVELOPER_DIR)
else ifneq ($(wildcard $(VOWKY_XCODE26)),)
  DEV_TOOLCHAIN := DEVELOPER_DIR=$(VOWKY_XCODE26)
else
  DEV_TOOLCHAIN :=
  $(warning ⚠ 未找到 /Applications/Xcode-26.app，使用系统默认 Xcode（构建将不含 SpeechAnalyzer 功能）)
endif

dev: ## 开发构建（Debug，带签名）
	cd VowKy && xcodegen generate && \
	$(DEV_TOOLCHAIN) xcodebuild build \
		-project VowKy.xcodeproj \
		-scheme VowKy \
		-configuration Debug \
		| tail -3

run: dev ## 构建并启动 App
	@pkill -x VowKy 2>/dev/null || true
	@sleep 0.5
	@APP_PATH=$$($(DEV_TOOLCHAIN) xcodebuild -project VowKy/VowKy.xcodeproj -scheme VowKy -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $$3}'); \
	open "$$APP_PATH/VowKy.app"
