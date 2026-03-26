// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "core/core/MarketCore.sol";
import "core/core/MarketFactory.sol";
import "core/core/DLMMEngine.sol";
import "core/core/LimitOrderManager.sol";
import "core/core/LPManager.sol";
import "core/core/SwapHookRouter.sol";
import "core/core/MarketRouter.sol";
import "core/core/MarketViewer.sol";
import "core/tokens/OutcomeToken.sol";
import "core/tokens/LPPositionNFT.sol";
import "core/test/MockERC20.sol";
import "oracle/OptimisticOracleArbitration.sol";

contract DeployFull is Script {
    // Standard Anvil dev accounts
    address constant DEPLOYER  = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 constant DEPLOY_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Anvil accounts 1-9 used as oracle participants
    address constant ARB1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant ARB2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant ARB3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant PROPOSER1 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    function run() external {
        vm.startBroadcast(DEPLOY_PK);

        // ── Collateral ────────────────────────────────────────────────────────
        // Mint 100M USDC to deployer; distribute to agents via transfer below
        MockERC20 usdc = new MockERC20("Mock USDC", "USDC", 100_000_000e18, DEPLOYER);

        // ── Core tokens ───────────────────────────────────────────────────────
        OutcomeToken outcomeToken = new OutcomeToken();
        LPPositionNFT lpNFT = new LPPositionNFT();

        // ── DLMMEngine ────────────────────────────────────────────────────────
        DLMMEngine engineImpl = new DLMMEngine();
        bytes memory engineInit = abi.encodeCall(
            DLMMEngine.initialize, (50, 30, 60, 5000, 100, 1000, 100_000, DEPLOYER)
        );
        DLMMEngine engine = DLMMEngine(address(new ERC1967Proxy(address(engineImpl), engineInit)));

        // ── MarketCore ────────────────────────────────────────────────────────
        MarketCore coreImpl = new MarketCore();
        bytes memory coreInit = abi.encodeCall(
            MarketCore.initialize, (address(engine), address(outcomeToken), address(usdc))
        );
        MarketCore marketCore = MarketCore(address(new ERC1967Proxy(address(coreImpl), coreInit)));

        // ── LPManager ─────────────────────────────────────────────────────────
        LPManager lpImpl = new LPManager();
        bytes memory lpInit = abi.encodeCall(
            LPManager.initialize,
            (address(marketCore), address(engine), address(usdc), address(outcomeToken), address(lpNFT), address(0))
        );
        LPManager lpManager = LPManager(address(new ERC1967Proxy(address(lpImpl), lpInit)));

        // ── LimitOrderManager ─────────────────────────────────────────────────
        LimitOrderManager lomImpl = new LimitOrderManager();
        bytes memory lomInit = abi.encodeCall(
            LimitOrderManager.initialize,
            (address(marketCore), address(engine), address(usdc), address(outcomeToken))
        );
        LimitOrderManager limitOrderMgr = LimitOrderManager(address(new ERC1967Proxy(address(lomImpl), lomInit)));

        // ── MarketFactory ─────────────────────────────────────────────────────
        MarketFactory factoryImpl = new MarketFactory();
        bytes memory factoryInit = abi.encodeCall(
            MarketFactory.initialize,
            (address(marketCore), address(lpManager), address(engine), address(usdc), address(outcomeToken))
        );
        MarketFactory marketFactory = MarketFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));
        lpManager.setFactory(address(marketFactory));

        // ── SwapHookRouter ────────────────────────────────────────────────────
        SwapHookRouter hookImpl = new SwapHookRouter();
        SwapHookRouter hookRouter = SwapHookRouter(
            address(new ERC1967Proxy(address(hookImpl), abi.encodeCall(SwapHookRouter.initialize, ())))
        );

        // ── MarketRouter ──────────────────────────────────────────────────────
        MarketRouter mrImpl = new MarketRouter();
        bytes memory mrInit = abi.encodeCall(
            MarketRouter.initialize,
            (address(marketCore), address(limitOrderMgr), address(usdc), address(outcomeToken))
        );
        MarketRouter router = MarketRouter(address(new ERC1967Proxy(address(mrImpl), mrInit)));

        // ── OptimisticOracleArbitration ───────────────────────────────────────
        OptimisticOracleArbitration oracle = new OptimisticOracleArbitration(address(usdc));

        // ── MarketViewer ──────────────────────────────────────────────────────
        MarketViewer viewer = new MarketViewer(
            address(marketCore), address(engine), address(marketFactory), address(oracle)
        );

        // ── Wire everything ───────────────────────────────────────────────────
        outcomeToken.setMinter(address(marketCore));
        lpNFT.setMinter(address(lpManager));
        marketCore.setAuthorizedMarketCreator(address(marketFactory));
        marketCore.setAuthorizedSwapCaller(address(router), true);
        marketCore.setAuthorizedSwapCaller(address(limitOrderMgr), true);
        marketCore.setAuthorizedHookCaller(address(limitOrderMgr), true);
        marketCore.setAuthorizedHookCaller(address(lpManager), true);
        marketCore.setSwapHook(address(hookRouter));
        marketCore.setOracle(address(oracle));
        hookRouter.addHook(address(limitOrderMgr));
        hookRouter.addHook(address(lpManager));
        limitOrderMgr.setAuthorizedCaller(address(hookRouter), true);
        lpManager.setAuthorizedCaller(address(hookRouter), true);

        // ── OOA setup ─────────────────────────────────────────────────────────
        oracle.addArbitrator(ARB1);
        oracle.addArbitrator(ARB2);
        oracle.addArbitrator(ARB3);
        oracle.addProposer(PROPOSER1, false);   // regular proposer
        oracle.addProposer(DEPLOYER, true);     // platform proposer (no bond)
        usdc.approve(address(oracle), 10_000e18);
        oracle.addReserveFund(10_000e18);

        // ── Transfer USDC to agent wallets (accounts 1-9 from Anvil mnemonic) ─
        // deploy/deployer.py funds the rest via cast send after reading all wallet addresses
        usdc.transfer(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 10_000e18);
        usdc.transfer(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, 10_000e18);
        usdc.transfer(0x90F79bf6EB2c4f870365E785982E1f101E93b906, 10_000e18);
        usdc.transfer(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65, 10_000e18);
        usdc.transfer(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc, 10_000e18);
        usdc.transfer(0x976EA74026E726554dB657fA54763abd0C3a0aa9, 10_000e18);
        usdc.transfer(0x14dC79964da2C08b23698B3D3cc7Ca32193d9955, 10_000e18);
        usdc.transfer(0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f, 10_000e18);
        usdc.transfer(0xa0Ee7A142d267C1f36714E4a8F75612F20a79720, 10_000e18);

        vm.stopBroadcast();

        // ── Output addresses as parseable JSON ────────────────────────────────
        string memory json = string(abi.encodePacked(
            'DEPLOY_JSON:{"usdc":"',          vm.toString(address(usdc)),         '"',
            ',"outcomeToken":"',              vm.toString(address(outcomeToken)),  '"',
            ',"engine":"',                   vm.toString(address(engine)),        '"',
            ',"marketCore":"',               vm.toString(address(marketCore)),    '"',
            ',"lpManager":"',                vm.toString(address(lpManager)),     '"',
            ',"limitOrderMgr":"',            vm.toString(address(limitOrderMgr)), '"',
            ',"marketFactory":"',            vm.toString(address(marketFactory)), '"',
            ',"hookRouter":"',               vm.toString(address(hookRouter)),    '"',
            ',"router":"',                   vm.toString(address(router)),        '"',
            ',"oracle":"',                   vm.toString(address(oracle)),        '"',
            ',"viewer":"',                   vm.toString(address(viewer)),        '"',
            '}'
        ));
        console.log(json);
    }
}
