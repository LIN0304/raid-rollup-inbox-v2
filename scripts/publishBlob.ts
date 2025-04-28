import { ethers } from "hardhat";
import { readFileSync } from "fs";

async function main() {
  // Configuration - replace with actual addresses or load from environment/deployment file
  const INBOX_ADDRESS = process.env.INBOX_ADDRESS || "0xYourInboxAddress";
  const REGISTRY_ADDRESS = process.env.REGISTRY_ADDRESS || "0xYourRegistryAddress";
  const BLOB_PATH = process.env.BLOB_PATH || "./blob.json";
  const SLOT = process.env.SLOT ? BigInt(process.env.SLOT) : 123456n;
  const REPLACE_UNSAFE_HEAD = process.env.REPLACE_UNSAFE_HEAD === "false" ? false : true;

  console.log("Configuration:");
  console.log(`- Inbox Address: ${INBOX_ADDRESS}`);
  console.log(`- Registry Address: ${REGISTRY_ADDRESS}`);
  console.log(`- Blob Path: ${BLOB_PATH}`);
  console.log(`- Slot: ${SLOT}`);
  console.log(`- Replace Unsafe Head: ${REPLACE_UNSAFE_HEAD}`);

  // Get signer
  const [signer] = await ethers.getSigners();
  console.log(`\nPublishing as: ${signer.address}`);

  // Connect to contracts
  const inbox = await ethers.getContractAt("RaidInbox", INBOX_ADDRESS, signer);
  const registry = await ethers.getContractAt("PreconfRegistry", REGISTRY_ADDRESS, signer);

  // Check if signer is a preconfer
  const isPreconfer = await registry.isActivePreconfer(signer.address);
  if (!isPreconfer) {
    console.log("\n⚠️ WARNING: You are not registered as a preconfer!");
    console.log("Joining registry with minimum collateral...");
    
    const minCollateral = await registry.minCollateral();
    const joinTx = await registry.join({ value: minCollateral });
    await joinTx.wait();
    console.log(`✅ Joined registry with ${ethers.formatEther(minCollateral)} ETH collateral`);
  } else {
    console.log("✅ Already registered as a preconfer");
  }

  // Read blob data
  console.log(`\nReading blob from ${BLOB_PATH}...`);
  let rawBlob;
  try {
    rawBlob = readFileSync(BLOB_PATH);
    console.log(`✅ Loaded blob (${rawBlob.length} bytes)`);
  } catch (error) {
    console.error(`Error reading blob file: ${error.message}`);
    process.exit(1);
  }

  // Create a dummy proof for testing (would be replaced with real proof in production)
  console.log("\nGenerating validator proof...");
  const proof = ethers.AbiCoder.defaultAbiCoder().encode(
    ["tuple(uint64,uint64,address,bytes32[])"],
    [
      [
        SLOT,
        0n, // proposerIndex
        signer.address, // proposerAddr
        [] // branch (empty for testing)
      ]
    ]
  );
  console.log("✅ Generated test proof");

  // Publish blob
  console.log("\nPublishing blob to RaidInbox...");
  try {
    const tx = await inbox.publish(rawBlob, SLOT, REPLACE_UNSAFE_HEAD, proof);
    console.log(`Transaction hash: ${tx.hash}`);
    
    const receipt = await tx.wait();
    console.log(`✅ Blob published successfully (gas used: ${receipt.gasUsed})`);
    
    // Extract publication ID from events
    const publishEvents = receipt.logs.filter(log => 
      log.topics[0] === inbox.interface.getEventTopic("NewUnsafeHead")
    );
    
    if (publishEvents.length > 0) {
      const event = inbox.interface.parseLog(publishEvents[0]);
      console.log(`\nNew unsafe head: Publication ID #${event.args.publicationId}`);
    }
  } catch (error) {
    console.error(`Error publishing blob: ${error.message}`);
    if (error.data) {
      // Try to decode the error
      try {
        const decodedError = inbox.interface.parseError(error.data);
        console.error(`Decoded error: ${decodedError.name}`);
      } catch (e) {
        console.error("Could not decode error data");
      }
    }
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });