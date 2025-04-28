import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // Configurable parameters
  const BEACON_ROOTS = process.env.BEACON_ROOTS || "0x000000000000000000000000000000000000Beac";
  const MIN_COLLATERAL = ethers.parseEther("1"); // 1 ETH
  const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS || deployer.address;

  console.log("Configuration:");
  console.log(`- Beacon Roots: ${BEACON_ROOTS}`);
  console.log(`- Min Collateral: ${MIN_COLLATERAL} ETH`);
  console.log(`- Treasury: ${TREASURY_ADDRESS}`);

  // Step 1: Deploy PublicationFeed
  console.log("\nDeploying PublicationFeed...");
  const PublicationFeed = await ethers.getContractFactory("PublicationFeed");
  const feed = await PublicationFeed.deploy();
  await feed.waitForDeployment();
  console.log(`PublicationFeed deployed to: ${await feed.getAddress()}`);

  // Step 2: Deploy RaidInbox (we'll update the registry address later)
  console.log("\nDeploying RaidInbox...");
  const tempRegistryAddress = deployer.address; // Temporary placeholder
  const RaidInbox = await ethers.getContractFactory("RaidInbox");
  const inbox = await RaidInbox.deploy(
    await feed.getAddress(),
    tempRegistryAddress, // Will be updated after registry deployment
    BEACON_ROOTS
  );
  await inbox.waitForDeployment();
  const inboxAddress = await inbox.getAddress();
  console.log(`RaidInbox deployed to: ${inboxAddress}`);

  // Step 3: Deploy PreconfRegistry with the actual RaidInbox address
  console.log("\nDeploying PreconfRegistry...");
  const PreconfRegistry = await ethers.getContractFactory("PreconfRegistry");
  const registry = await PreconfRegistry.deploy(
    MIN_COLLATERAL,
    TREASURY_ADDRESS,
    inboxAddress
  );
  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  console.log(`PreconfRegistry deployed to: ${registryAddress}`);

  // Step 4: Deploy BeaconOracle
  console.log("\nDeploying BeaconOracle...");
  const BeaconOracle = await ethers.getContractFactory("BeaconOracle");
  const oracle = await BeaconOracle.deploy(BEACON_ROOTS);
  await oracle.waitForDeployment();
  console.log(`BeaconOracle deployed to: ${await oracle.getAddress()}`);

  // Final deployment addresses
  console.log("\nDeployment Summary:");
  console.log(`- PublicationFeed: ${await feed.getAddress()}`);
  console.log(`- PreconfRegistry: ${registryAddress}`);
  console.log(`- RaidInbox: ${inboxAddress}`);
  console.log(`- BeaconOracle: ${await oracle.getAddress()}`);

  // Warning about registry address update
  console.log("\n⚠️ IMPORTANT: The RaidInbox was deployed with a temporary registry address.");
  console.log("You must call updateRegistry() on the RaidInbox contract with the actual registry address.");
  
  // Save deployment addresses to a file for easy access
  const fs = require('fs');
  const deploymentInfo = {
    network: process.env.HARDHAT_NETWORK || 'localhost',
    timestamp: new Date().toISOString(),
    addresses: {
      publicationFeed: await feed.getAddress(),
      preconfRegistry: registryAddress,
      raidInbox: inboxAddress,
      beaconOracle: await oracle.getAddress()
    },
    parameters: {
      beaconRoots: BEACON_ROOTS,
      minCollateral: MIN_COLLATERAL.toString(),
      treasury: TREASURY_ADDRESS
    }
  };

  fs.writeFileSync(
    `deployment-${deploymentInfo.network}-${Math.floor(Date.now() / 1000)}.json`,
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log("\nDeployment information saved to file.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });