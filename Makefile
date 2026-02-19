.PHONY: build-dev build-prod deploy-dev deploy-prod bump-patch bump-minor bump-major preflight verify-dev verify-prod help

help: ## 显示帮助信息
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build-dev: ## 构建 Dev 版本 DMG
	./deploy/build.sh dev

build-prod: ## 构建 Prod 版本 DMG（含公证）
	./deploy/build.sh prod

deploy-dev: ## 构建并部署到 dev.vowky.com
	./deploy/deploy.sh dev

deploy-prod: ## 构建并部署到 vowky.com（生产）
	./deploy/deploy.sh prod

bump-patch: ## 版本号 patch +1（如 1.0.0 → 1.0.1）
	./deploy/bump-version.sh patch

bump-minor: ## 版本号 minor +1（如 1.0.0 → 1.1.0）
	./deploy/bump-version.sh minor

bump-major: ## 版本号 major +1（如 1.0.0 → 2.0.0）
	./deploy/bump-version.sh major

preflight: ## 部署前环境预检
	./deploy/preflight.sh

verify-dev: ## 验证 dev 环境部署结果
	./deploy/verify.sh dev

verify-prod: ## 验证 prod 环境部署结果
	./deploy/verify.sh prod
