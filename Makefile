include .env

verify-hl:
	@if [ -z "$(address)" ]; then echo "Error: address parameter is required. Usage: make verify-purrsec address=0x... path=src/Contract.sol:Contract"; exit 1; fi
	@if [ -z "$(path)" ]; then echo "Error: path parameter is required. Usage: make verify-purrsec address=0x... path=src/Contract.sol:Contract"; exit 1; fi
	@echo "Attempting verification with ETHERSCAN for $(address) with path $(path)"
	@forge verify-contract $(address) $(path) -r $(HL_RPC_URL) || echo "ETHERSCAN verification failed, trying Sourcify..."
	@echo "Verifying contract at $(address) with path $(path) on chain 999 using Sourcify"
	@ETHERSCAN_API_URL="" ETHERSCAN_API_KEY="" forge verify-contract $(address) $(path) \
		--chain-id 999 \
		--verifier sourcify \
		--verifier-url https://sourcify.parsec.finance/verify

check-configs: 
	@echo "l1_file: ${l1_file} l2_file ${l2_file}"
	bun lzConfigCheck.cjs ${l1_file} ${l2_file}

update-salts:
	@if [ -z "$(files)" ]; then echo "Error: at least one file is required. Usage: make update-salts files=\"beatUSD-L1.json beatUSD-L2.json\""; exit 1; fi
	@node incrementSalt.cjs $(files) 

checkL1:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge test --mp test/LiveDeploy.t.sol --fork-url=${L1_RPC_URL}

checkL2:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge test --mp test/LiveDeploy.t.sol --fork-url=${L2_RPC_URL}

deployL1:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	cp ./deployment-config/out-template.json ./deployment-config/out.json
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge script script/deploy/deployAll.s.sol --sig "run(string)" $(file) --fork-url=${L1_RPC_URL}

deployL2:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	cp ./deployment-config/out-template.json ./deployment-config/out.json
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge script script/deploy/deployAll.s.sol --sig "run(string)" $(file) --fork-url=${L2_RPC_URL}

live-deployL1:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	cp ./deployment-config/out-template.json ./deployment-config/out.json
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge script script/deploy/deployAll.s.sol --sig "run(string)" $(file) --fork-url=${L1_RPC_URL} --private-key=$(PRIVATE_KEY) --broadcast --slow --verify
	mv ./deployment-config/out.json ./deployment-config/outL1.json

live-deployL2:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	cp ./deployment-config/out-template.json ./deployment-config/out.json
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge script script/deploy/deployAll.s.sol --sig "run(string)" $(file) --fork-url=${L2_RPC_URL} --private-key=$(PRIVATE_KEY) --broadcast --slow --verify
	mv ./deployment-config/out.json ./deployment-config/outL2.json

prettier:
	prettier --write '**/*.{md,yml,yaml,ts,js}'

solhint:
	solhint -w 0 'src/**/*.sol'
    
slither: 
	slither src

prepare:
	husky

deploy-createx-l1: 
	forge script script/DeployCustomCreatex.s.sol --rpc-url ${L1_RPC_URL} --private-key ${PRIVATE_KEY} --slow --no-metadata

deploy-createx-l2:
	forge script script/DeployCustomCreatex.s.sol --rpc-url ${L2_RPC_URL} --private-key ${PRIVATE_KEY} --slow --no-metadata

check-configs: 
	bun lzConfigCheck.cjs

chain1 := $(shell cast chain-id -r $(L1_RPC_URL))
chain2 := $(shell cast chain-id -r $(L2_RPC_URL))
symbol := $(shell cat deployment-config/$(fileL1) | jq -r ".boringVault.boringVaultSymbol")
post-deploy:
	mkdir -p ./nucleus-deployments/$(symbol)
	mv ./deployment-config/outL1.json ./nucleus-deployments/$(symbol)/L1Out.json
	mv ./deployment-config/outL2.json ./nucleus-deployments/$(symbol)/L2Out.json
	cp ./broadcast/deployAll.s.sol/$(chain1)/run-latest.json ./nucleus-deployments/$(symbol)/L1.json
	cp ./broadcast/deployAll.s.sol/$(chain2)/run-latest.json ./nucleus-deployments/$(symbol)/L2.json
	cp ./deployment-config/$(fileL1) ./nucleus-deployments/$(symbol)/L1Config.json
	cp ./deployment-config/$(fileL2) ./nucleus-deployments/$(symbol)/L2Config.json
	cd nucleus-deployments && git checkout -b $(symbol) && git add . && git commit -m "$(symbol) deployment" && git push origin $(symbol) && git checkout main
